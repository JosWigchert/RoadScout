import SwiftUI
import MapKit

struct ContentView: View {
    @State private var model = DrivingModel()
    @State private var navigation: NavigationModel
    @State private var weather = WeatherModel()
    @State private var cameraAlerts: CameraAlertModel
    @State private var drivingSpeech: SpeechAnnouncer
    @State private var drivingSession: DrivingSessionCoordinator
    @State private var traffic: TrafficModel
    @State private var selectedTraffic: TrafficFeature?
    @State private var cameraBounds: CameraBounds?
    @State private var selectedCamera: CameraRecord?
    @State private var planningLocation: PlanningLocationModel
    @State private var selectedPlace: Destination?
    @State private var routePlanner: RoutePlanningModel
    @State private var routingCatalog: RoutingCatalog
    @State private var originSearch: PlaceSearchModel
    @StateObject private var recents: PlaceRecents
    @State private var search: PlaceSearchModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var following = true
    @State private var planningCamera: MapCameraPosition = .automatic
    @State private var lastMapCamera: MapCamera?
    @State private var source: DrivingSource = .live
    @State private var showingSettings = false
    @State private var showingRouteInfo = false
    @State private var demoError: String?
    @AppStorage("speedUnit") private var unit: SpeedUnit = .localeDefault
    @AppStorage("routingAPIURL") private var apiURL = AppConfiguration.routingAPIBaseURL
    @AppStorage("avoidTolls") private var avoidTolls = false
    @AppStorage("avoidHighways") private var avoidHighways = false
    @AppStorage("includeExperimentalRouting") private var includeExperimentalRouting = false
    @AppStorage("cameraWarningsEnabled") private var camerasEnabled = true
    @AppStorage("showRoofDownWeather") private var showRoofDownWeather = true
    @AppStorage("showLiveTraffic") private var showLiveTraffic = true
    @AppStorage("cameraAudioEnabled") private var cameraAudioEnabled = true
    @AppStorage("cameraWarningDistance") private var cameraWarningDistance = 500.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drawerDetent: DrawerDetent = .collapsed
    @State private var confirmingClearRecents = false
    @FocusState private var searchFocused: Bool
    // initialized in init() with a shared PlaceRecents

     private var touchTarget: CGFloat = 44
     private var topOverlaySpacing: CGFloat = 12
     private var smallSpacing: CGFloat = 8
     private var drawerSpacing: CGFloat = 10
     private let drawerContentInset: CGFloat = 16
     // A 44-point control has a 22-point radius; adding the inset keeps the curves concentric.
     private let drawerCornerRadius: CGFloat = 38
     private var searchBarPadding: CGFloat = 10
     private var cameraDistance: Double = 900
     private var quickAnimationDuration: Double = 0.12
     private var springResponse: Double = 0.35
     private var springDamping: Double = 0.82

    init(model: DrivingModel = DrivingModel(), initialDrawerDetent: PresentationDetent = .height(76),
         searchModel: PlaceSearchModel? = nil, planningLocation: PlanningLocationModel = PlanningLocationModel(),
         initialDestination: Destination? = nil, navigationModel: NavigationModel? = nil,
         routePlanner: RoutePlanningModel = RoutePlanningModel(defaults: .standard), originSearchModel: PlaceSearchModel? = nil,
         routeCatalog: RoutingCatalog = RoutingCatalog(), initialFollowing: Bool = true,
         cameraModel: CameraAlertModel = CameraAlertModel(), initialSelectedCamera: CameraRecord? = nil) {
        _model = State(wrappedValue: model)
        _selectedCamera = State(initialValue: initialSelectedCamera)
        _following = State(initialValue: initialFollowing)
        let speech = SpeechAnnouncer()
        let navigation = navigationModel ?? NavigationModel(audio: speech)
        let traffic = TrafficModel()
        _traffic = State(wrappedValue: traffic)
        _drivingSpeech = State(wrappedValue: speech)
        _navigation = State(wrappedValue: navigation)
        _cameraAlerts = State(wrappedValue: cameraModel)
        _drivingSession = State(wrappedValue: DrivingSessionCoordinator(driving: model,
            navigation: navigation, cameras: cameraModel, speech: speech, traffic: traffic))
        _planningLocation = State(wrappedValue: planningLocation)
        _selectedPlace = State(initialValue: initialDestination)
        _routePlanner = State(wrappedValue: routePlanner)
        _routingCatalog = State(wrappedValue: routeCatalog)
        routePlanner.apply(options: routeCatalog.options)
        _drawerDetent = State(initialValue: initialDestination == nil ? DrawerDetent(presentationDetent: initialDrawerDetent) : (routePlanner.isEditingOrigin ? .expanded : .half))
        _source = State(initialValue: model.source)
        if let fix = model.fix {
            _camera = State(initialValue: .camera(MapCamera(centerCoordinate: fix.coordinate,
                                                           distance: 650, heading: model.heading, pitch: 45)))
        }
        if let initialDestination {
            _camera = State(initialValue: .rect(PlaceMapFocus.rect(for: initialDestination.point)))
        }
        let recents = searchModel?.recents ?? PlaceRecents()
        _recents = StateObject(wrappedValue: recents)
        _search = State(wrappedValue: searchModel ?? PlaceSearchModel(recents: recents))
        _originSearch = State(wrappedValue: originSearchModel ?? PlaceSearchModel(recents: recents))
    }

    var body: some View {
        GeometryReader { geometry in
            let routeGeometry = navigation.selectedRoute.map {
                RouteProgressGeometry(route: $0, traveledMeters: model.isDriving ? navigation.progress?.traveledMeters : nil)
            }
            let trafficFeatures = showLiveTraffic ? TrafficDisplayFeature.make(traffic.visibleFeatures,
                route: navigation.selectedRoute, traveled: model.isDriving ? (navigation.progress?.traveledMeters ?? 0) : 0,
                center: cameraBounds?.center) : []
            ZStack(alignment: .bottom) {
                DrivingMapSurface(position: $camera, following: $following, driving: model.isDriving,
                    motion: model.motion, fix: model.fix, source: model.source, fallbackHeading: model.heading,
                    cameraEnded: { snapshot in
                        lastMapCamera = snapshot.camera
                        if cameraBounds != snapshot.bounds { cameraBounds = snapshot.bounds }
                    }) {
                    if !model.isDriving {
                        ForEach(navigation.routes.filter { $0.id != navigation.selectedRoute?.id }) { route in
                            MapPolyline(coordinates: route.geometry.map(\.coordinate))
                                .stroke(.gray.opacity(0.75), lineWidth: 5)
                        }
                    }
                    TrafficMapContent(features: trafficFeatures.filter { $0.feature.kind == "flow" && $0.feature.routeStartMeters == nil }, select: { selectedTraffic = $0 })
                    if showLiveTraffic, let offer = traffic.offer {
                        MapPolyline(coordinates: offer.route.geometry.map(\.coordinate))
                            .stroke(.purple.opacity(0.8), style: StrokeStyle(lineWidth: 5, dash: [8, 5]))
                    }
                    if let routeGeometry {
                        RouteMapContent(geometry: routeGeometry)
                    }
                    TrafficMapContent(features: trafficFeatures.filter { $0.feature.kind != "flow" || $0.feature.routeStartMeters != nil }, select: { selectedTraffic = $0 })
                    if camerasEnabled {
                        CameraMapContent(cameras: cameraAlerts.cameras, zones: cameraAlerts.zones,
                                         bounds: cameraBounds,
                                         selectCamera: { selectedCamera = $0 },
                                          selectCluster: { zoom(to: $0) })
                    }
                    if !model.isDriving, showRoofDownWeather,
                       let route = navigation.selectedRoute,
                       let response = weather.state(for: route).response, response.hasRainRisk {
                        WeatherMapContent(response: response)
                    }
                    if !model.isDriving, selectedPlace != nil {
                        if let origin = routePlanner.customOrigin {
                            Marker(origin.name, systemImage: "circle.fill", coordinate: origin.coordinate).tint(.gray)
                        }
                        ForEach(Array(navigation.routes.enumerated()), id: \.element.id) { index, route in
                            Annotation("Route option", coordinate: PlaceMapFocus.labelPoint(on: route, fraction: min(0.8, 0.35 + Double(index) * 0.25)).coordinate) {
                                Button { navigation.select(route) } label: {
                                    Text("\(max(1, Int(ceil(route.durationSeconds / 60)))) min")
                                        .font(.caption.bold()).padding(8)
                                        .foregroundStyle(navigation.selectedRoute?.id == route.id ? Color.white : Color.primary)
                                        .background(navigation.selectedRoute?.id == route.id ? Color.blue : Color(.secondarySystemBackground),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(RoutePresentation.title(for: route, in: navigation.routes))
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if let destination = selectedPlace ?? navigation.destination {
                        Marker(destination.name, systemImage: destination.symbol ?? "mappin", coordinate: destination.point.coordinate)
                            .tint(PlaceCategoryStyle.color(for: destination.symbol))
                    }
                    if model.fix == nil, let point = planningLocation.currentPoint {
                        Annotation("Your position", coordinate: point.coordinate) {
                            Circle().fill(.blue).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: topOverlaySpacing) {
                    topOverlay
                        .accessibilityElement(children: .contain)
                    if let selectedCamera {
                        CameraDetailCard(camera: selectedCamera, unit: unit) { self.selectedCamera = nil }
                            .padding(.horizontal, topOverlaySpacing)
                            .transition(.opacity)
                    }
                    if let feature = selectedTraffic {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(feature.title).font(.headline); Spacer(); Button("Close") { selectedTraffic = nil } }
                            Text("\(feature.sourceId) · Updated \(feature.observedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let seconds = feature.travelSeconds { Text("Measured travel time: \(Int(seconds / 60)) min") }
                            Text(feature.matched ? "Matched road geometry" : "Reported location · road/direction may be approximate")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 12)
                    }
                    Spacer(minLength: 0)
                    if model.isDriving {
                        if showLiveTraffic, let offer = traffic.offer {
                            TrafficOfferCard(offer: offer,
                                accept: { traffic.accept(fix: model.fix, navigation: navigation) }, reject: { traffic.reject() })
                                .padding(.horizontal, 16)
                        }
                        drivingControls(compact: geometry.size.width > geometry.size.height)
                            .transition(driveControlTransition)
                    }
                }
                .safeAreaPadding()
                .animation(driveTransitionAnimation, value: model.isDriving)
            }
            .onChange(of: camera) { _, newValue in
                if newValue.positionedByUser { following = false }
            }
            .onChange(of: model.fix) { _, _ in
                updateCamera()
            }
            .onChange(of: model.source) { _, value in source = value }
            .onChange(of: navigation.selectedRoute) { _, _ in
                refreshCameraData()
                refreshTrafficData()
                    if let route = navigation.selectedRoute {
                    if model.isDriving {
                        updateCamera()
                        return
                    }
                    if selectedPlace != nil {
                        focusRoute(route, viewport: geometry.size)
                        return
                    }
                    if !navigation.isNavigating { setDrawerDetent(.half) }
                    following = false
                    camera = .rect(MKPolyline(coordinates: route.geometry.map(\.coordinate), count: route.geometry.count).boundingMapRect)
                }
            }
            .onChange(of: navigation.routes) { _, routes in
                weather.clear()
                if !model.isDriving, showRoofDownWeather {
                    weather.loadAll(routes: routes, endpoint: apiURL)
                }
            }
            .onChange(of: showRoofDownWeather) { _, enabled in
                weather.clear()
                if enabled, !model.isDriving { weather.loadAll(routes: navigation.routes, endpoint: apiURL) }
            }
            .onChange(of: model.isDriving) { _, driving in
                UIApplication.shared.isIdleTimerDisabled = driving && scenePhase == .active
                searchFocused = false
                if driving {
                    weather.clear()
                    following = true
                    search.cancel()
                    originSearch.cancel()
                    planningLocation.stop(clearFix: true)
                    updateCamera()
                } else {
                    cameraAlerts.stop()
                    drivingSpeech.stop()
                    showingRouteInfo = false
                    navigation.pause()
                    search.updateOrigin(planningLocation.currentPoint)
                    drawerDetent = selectedPlace == nil ? .collapsed : .half
                    if source != .live { exitDemo() }
                    withAnimation(reduceMotion ? nil : driveTransitionAnimation) {
                        if planningCamera.camera != nil || planningCamera.rect != nil {
                            camera = planningCamera
                        } else if let lastMapCamera {
                            camera = .camera(MapCamera(centerCoordinate: lastMapCamera.centerCoordinate,
                                                       distance: 5_000, heading: 0, pitch: 0))
                        } else {
                            camera = .automatic
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                UIApplication.shared.isIdleTimerDisabled = model.isDriving && phase == .active
                if phase == .background {
                    drivingSession.enterBackground()
                    planningLocation.stop(clearFix: true)
                    search.cancel()
                    originSearch.cancel()
                    weather.clear()
                } else if phase == .active {
                    drivingSession.enterForeground()
                    refreshCameraData()
                }
            }
            .onChange(of: planningLocation.fix) { _, _ in
                guard scenePhase != .background, !model.isDriving else { return }
                search.updateOrigin(searchOrigin)
                if selectedPlace == nil, following, let point = planningLocation.currentPoint {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                        camera = .camera(MapCamera(centerCoordinate: point.coordinate, distance: 5_000, heading: 0, pitch: 0))
                    }
                }
                if selectedPlace == nil, !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    runSearch()
                } else if selectedPlace != nil {
                    previewSelectedDestination()
                }
            }
            .onChange(of: search.selectedDestination) { _, destination in
                if let destination { selectDestination(destination) }
            }
            .onChange(of: drawerDetent) { _, detent in
                if detent == .half, selectedPlace != nil, !routePlanner.isEditingOrigin,
                   let route = navigation.selectedRoute, !model.isDriving {
                    focusRoute(route, viewport: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, size in
                if selectedPlace != nil, !model.isDriving, let route = navigation.selectedRoute {
                    focusRoute(route, viewport: size)
                }
            }
            .onChange(of: avoidTolls) { _, _ in if selectedPlace != nil, !model.isDriving { previewSelectedDestination() } }
            .onChange(of: avoidHighways) { _, _ in if selectedPlace != nil, !model.isDriving { previewSelectedDestination() } }
            .onChange(of: routePlanner.profile) { _, _ in if selectedPlace != nil, !model.isDriving { previewSelectedDestination() } }
            .onChange(of: routePlanner.maxExtraDurationPercent) { _, _ in if selectedPlace != nil, !model.isDriving { previewSelectedDestination() } }
            .onChange(of: includeExperimentalRouting) { _, _ in
                routePlanner.applyCatalog(routingCatalog, includeExperimental: includeExperimentalRouting)
                if selectedPlace != nil, !model.isDriving { previewSelectedDestination() }
            }
            .onChange(of: routingCatalog.options) { _, _ in
                routePlanner.applyCatalog(routingCatalog, includeExperimental: includeExperimentalRouting)
            }
            .onChange(of: apiURL) { _, newValue in
                traffic.clear()
                weather.clear()
                cameraAlerts.clear()
                drivingSpeech.cancelCameraWarnings()
                routingCatalog.load(endpoint: newValue)
                configureDrivingSession()
                refreshCameraData()
            }
            .task(id: cameraBounds) { if !model.isDriving { refreshCameraData(); refreshTrafficData() } }
            .onChange(of: showLiveTraffic) { _, enabled in
                configureDrivingSession()
                if enabled { refreshTrafficData() } else { selectedTraffic = nil; traffic.clear() }
            }
            .onChange(of: cameraAlerts.cameras) { _, cameras in
                if let selectedCamera, !cameras.contains(where: { $0.id == selectedCamera.id }) {
                    self.selectedCamera = nil
                }
            }
            .onChange(of: camerasEnabled) { _, enabled in
                configureDrivingSession()
                if !enabled {
                    selectedCamera = nil
                    cameraAlerts.clear()
                    drivingSpeech.cancelCameraWarnings()
                } else {
                    refreshCameraData()
                }
            }
            .onChange(of: cameraAudioEnabled) { _, enabled in
                configureDrivingSession()
                if !enabled { drivingSpeech.cancelCameraWarnings() }
            }
            .onChange(of: cameraWarningDistance) { _, _ in configureDrivingSession() }
            .sheet(isPresented: .constant(!model.isDriving)) {
                bottomDrawer(geometry: geometry)
                    .presentationDetents(selectedPlace == nil ? [DrawerDetent.collapsed.presentationDetent, .medium, .large] : [.medium, .large], selection: Binding(
                        get: { drawerDetent.presentationDetent },
                        set: { drawerDetent = DrawerDetent(presentationDetent: $0) }
                    ))
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(drawerCornerRadius)
                    .presentationBackgroundInteraction(.enabled(upThrough: .large))
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.none)
                    .interactiveDismissDisabled()
                    .sheet(isPresented: $showingSettings) { settings }
                    .confirmationDialog("Clear recent destinations?", isPresented: $confirmingClearRecents, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { recents.clear() }
                        Button("Cancel", role: .cancel) { }
                    }
                    .alert("Demo unavailable", isPresented: Binding(get: { demoError != nil }, set: { if !$0 { demoError = nil } })) {
                        Button("OK") { demoError = nil }
                    } message: { Text(demoError ?? "") }
            }
            .task {
                configureDrivingSession()
                routingCatalog.load(endpoint: apiURL)
                guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                apiURL = AppConfiguration.migratedRoutingAPIURL(apiURL)
                configureDrivingSession()
                routePlanner.applyCatalog(routingCatalog, includeExperimental: includeExperimentalRouting)
                refreshCameraData()
                refreshTrafficData()
                if selectedPlace != nil { previewSelectedDestination() }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--navigation-replay") {
                    startDemo(.navigationReplay)
                } else if ProcessInfo.processInfo.arguments.contains("--replay") {
                    startDemo(.replay)
                }
                #endif
            }
            .task {
                guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if scenePhase == .active {
                        refreshCameraData()
                        refreshTrafficData()
                        weather.expireCachedForecasts()
                    }
                }
            }
        }
    }

    private var driveTransitionAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.55, dampingFraction: 0.86)
    }

    private var driveControlTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.75).combined(with: .opacity)
    }

    // No live posted-limit source is available yet. Never infer a limit from GPS speed.
    private var speedDisplay: SpeedDisplayState {
        SpeedDisplayState(metersPerSecond: model.metersPerSecond, unit: unit)
    }

    private var topOverlay: some View {
        HStack(alignment: .top, spacing: topOverlaySpacing) {
            if model.isDriving {
                DrivingSpeedometer(display: speedDisplay)
                    .transition(driveControlTransition.combined(with: reduceMotion ? .identity : .move(edge: .leading)))
            } else {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: smallSpacing)
            if model.isDriving {
                DrivingSpeedLimit(display: speedDisplay)
                    .transition(driveControlTransition.combined(with: reduceMotion ? .identity : .move(edge: .trailing)))
            } else {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                }
                .buttonStyle(MapIconButtonStyle())
                .accessibilityLabel("Settings")
            }
        }
    }

    private func drivingControls(compact: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if camerasEnabled, let warning = cameraAlerts.alert {
                CameraWarningStrip(warning: warning, unit: unit, cached: cameraAlerts.isUsingCache,
                                   stale: cameraAlerts.metadata?.stale ?? true)
            }
            if !following, model.fix != nil {
                Button {
                    following = true
                    updateCamera()
                } label: {
                    Image(systemName: following ? "location.fill" : "location")
                }
                .buttonStyle(MapIconButtonStyle())
                .accessibilityLabel("Recenter and follow")
                .padding(.trailing, 4)
                .transition(.opacity)
            }
            DrivingDashboard(presentation: DrivingGuidancePresentation(route: navigation.selectedRoute,
                progress: navigation.progress, isNavigating: navigation.isNavigating, isPaused: navigation.isPaused,
                isLoading: navigation.isLoading, hasDestination: navigation.destination != nil,
                destinationName: navigation.destination?.name, message: navigation.message),
                unit: unit, muted: navigation.muted, hasRoute: navigation.selectedRoute != nil,
                hasFix: model.fix != nil, isDemo: source != .live, compact: compact,
                end: endDriving, toggleMute: { navigation.muted.toggle() },
                start: { navigation.start(fix: model.fix); following = true; updateCamera() },
                retry: { drivingSession.retryRoute() }, information: { showingRouteInfo = true })
                .sheet(isPresented: $showingRouteInfo) { routeInformation }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func zoom(to cluster: CameraCluster) {
        following = false
        let rect = cluster.bounds.mapRect
        let padding = max(200, max(rect.width, rect.height) * 0.35)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            camera = .rect(rect.insetBy(dx: -padding, dy: -padding))
        }
    }

    private func refreshCameraData() {
        if model.isDriving { drivingSession.refreshCameras(); return }
        guard camerasEnabled, source == .live, scenePhase != .background else { return }
        if let bounds = cameraBounds { cameraAlerts.fetch(bounds: bounds, route: navigation.selectedRoute, endpoint: apiURL) }
    }

    private func configureDrivingSession() {
        drivingSession.configure(DrivingSessionSettings(endpoint: apiURL, camerasEnabled: camerasEnabled,
            cameraAudioEnabled: cameraAudioEnabled, warningDistance: cameraWarningDistance, trafficEnabled: showLiveTraffic))
    }

    private func refreshTrafficData() {
        guard showLiveTraffic, model.source == .live, scenePhase == .active else { return }
        let bounds = model.fix.map { CameraViewportQuery.around(GeoPoint(latitude: $0.latitude, longitude: $0.longitude)) } ?? cameraBounds
        if let bounds { traffic.fetchMap(bounds: bounds, route: navigation.selectedRoute, endpoint: apiURL) }
    }

    private func endDriving() {
        showingRouteInfo = false
        if source != .live { exitDemo(); return }
        closeDestination()
        model.stop()
        setDrawerDetent(.collapsed)
    }

    private var routeInformation: some View {
        NavigationStack {
            List {
                if let route = navigation.selectedRoute {
                    Section("Route") {
                        Text(navigation.destination?.name ?? String(localized: "Current route"))
                        if let via = RoutePresentation.corridorLabel(for: route) { Text(via) }
                        Text("Arrival times are estimates; traffic coverage may be partial.").font(.footnote)
                        if let status = traffic.status { Text(status).font(.footnote) }
                    }
                    Section("Attribution") { Text(route.attribution).font(.footnote).textSelection(.enabled) }
                }
            }
            .navigationTitle("Route information")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingRouteInfo = false } } }
        }
    }

    private var statusLine: String {
        if search.isLoading { return String(localized: "Searching places…") }
        if let message = search.message, !message.isEmpty { return message }
        if navigation.isLoading { return String(localized: "Calculating route…") }
        if let message = navigation.message, !message.isEmpty { return message }
        if navigation.isNavigating { return String(localized: "Navigating") }
        if navigation.selectedRoute != nil { return String(localized: "Route preview") }
        if navigation.destination != nil { return String(localized: "Destination selected") }
        return model.status.title
    }

    private func updateCamera() {
        // DrivingMapSurface owns the frame-driven follow camera.
        guard !model.isDriving else { return }
        guard following, let fix = model.fix else { return }
        let nextCamera = MapCameraPosition.camera(MapCamera(centerCoordinate: fix.coordinate,
            distance: cameraDistance,
            heading: 0,
            pitch: 0))
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            camera = nextCamera
        }
    }

    private func bottomDrawer(geometry: GeometryProxy) -> some View {
        VStack(spacing: drawerSpacing) {
            if let selectedPlace {
                if routePlanner.isEditingOrigin {
                    RouteOriginSearchView(search: originSearch, currentLocation: searchOrigin, mapCenter: searchCenter, unit: unit,
                        useMyLocation: useCurrentRouteOrigin, choose: chooseRouteOrigin, cancel: cancelOriginSearch)
                } else {
                    RoutePlanningView(destination: selectedPlace, planner: routePlanner,
                        navigation: navigation, unit: unit,
                        weather: showRoofDownWeather ? weather : nil,
                        locationMessage: routePlanner.customOrigin == nil ? (planningLocation.isRequesting ? String(localized: "Finding your location…") : planningLocation.message) : nil,
                        editOrigin: editRouteOrigin, editDestination: editRouteDestination,
                        retry: { previewSelectedDestination(force: true) }, drive: driveToSelectedPlace, close: closeDestination)
                }
            } else {
                HStack(alignment: .center, spacing: drawerSpacing) {
                    searchBar
                    planningLocationButton
                    driveButton
                }
            if drawerDetent != .collapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if search.isLoading { ProgressView("Searching places…").padding(.horizontal, 4) }
                        if let message = search.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                        if !search.completions.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(search.completions.enumerated()), id: \.offset) { index, completion in
                                    Button {
                                        if completion.subtitle.isEmpty {
                                            search.query = completion.title
                                            searchFocused = false
                                            runSearch()
                                            setDrawerDetent(.half)
                                        } else {
                                            search.selectCompletion(completion, near: searchOrigin, searchCenter: searchCenter)
                                        }
                                    } label: {
                                        PlaceSuggestionRow(title: completion.title, subtitle: completion.subtitle)
                                    }
                                    .buttonStyle(.plain)
                                    if index < search.completions.count - 1 { Divider().padding(.leading, 72) }
                                }
                            }
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 24))
                        }
                        if !search.results.isEmpty {
                            HStack {
                                Text("Places").font(.headline)
                                Spacer()
                                Menu {
                                    Picker("Sort results", selection: $search.sortOrder) {
                                        ForEach(PlaceSortOrder.allCases) { order in Text(order.title).tag(order) }
                                    }
                                } label: {
                                    Label(searchOrigin == nil ? String(localized: "Best match") : search.sortOrder.title,
                                          systemImage: "arrow.up.arrow.down")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                                .disabled(searchOrigin == nil)
                            }
                            placeRows(search.results)
                            if searchOrigin != nil {
                                Text("Distances are approximate, measured in a straight line.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HStack {
                                Text("Recent").font(.headline)
                                Spacer()
                                if !recents.items.isEmpty {
                                    Button("Clear") { confirmingClearRecents = true }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Clear recent destinations")
                                }
                            }
                            if recents.items.isEmpty {
                                ContentUnavailableView("Where would you like to go?", systemImage: "magnifyingglass",
                                                       description: Text("Search for a place, shop or address."))
                            } else {
                                placeRows(PlaceProximity.updated(recents.items, origin: searchOrigin, order: .relevance), recent: true)
                            }
                        }
                        if let message = planningLocation.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("Location settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                        }
                        if searchOrigin == nil {
                            Button {
                                planningLocation.request(refresh: true)
                            } label: {
                                Label(planningLocation.isRequesting ? "Finding your location…" : "Use my location", systemImage: "location")
                                    .font(.subheadline).frame(minHeight: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(planningLocation.isRequesting)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .accessibilityElement(children: .contain)
            }
            }
        }
        .padding(.horizontal, drawerContentInset)
        .padding(.top, drawerContentInset)
        .padding(.bottom, drawerContentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private func placeRows(_ places: [Destination], recent: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(places.enumerated()), id: \.element.id) { index, destination in
                Button { selectDestination(destination) } label: {
                    PlaceResultRow(destination: destination, distance: placeDistance(destination))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .contextMenu {
                    if recent {
                        Button("Remove recent", systemImage: "trash", role: .destructive) { recents.remove(destination) }
                    }
                }
                .accessibilityAction(named: "Show destination details") { selectDestination(destination) }
                .accessibilityActions {
                    if recent {
                        Button("Remove recent") { recents.remove(destination) }
                    }
                }
                if index < places.count - 1 { Divider().padding(.leading, 72) }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 24))
    }

    private var searchOrigin: GeoPoint? {
        if let fix = model.fix { return GeoPoint(latitude: fix.latitude, longitude: fix.longitude) }
        return planningLocation.currentPoint
    }

    private var searchCenter: GeoPoint? {
        lastMapCamera.map { GeoPoint(latitude: $0.centerCoordinate.latitude, longitude: $0.centerCoordinate.longitude) }
    }

    private func placeDistance(_ destination: Destination) -> String? {
        searchOrigin.map { PlaceDistanceFormatter.string($0.distance(to: destination.point), unit: unit) }
    }

    private var driveButton: some View {
        Button {
            beginDriving()
        } label: {
            Label("Drive", systemImage: "steeringwheel")
                .labelStyle(.iconOnly)
                .frame(minWidth: touchTarget, minHeight: touchTarget)
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Start driving")
        .accessibilityHint("Closes planning and opens the driving map")
    }

    private func beginDriving() {
        planningCamera = lastMapCamera.map(MapCameraPosition.camera) ?? camera
        searchFocused = false
        following = true
        configureDrivingSession()
        model.start(source: source)
        if navigation.destination != nil, navigation.selectedRoute == nil { drivingSession.requestNavigationStart() }
    }

    private var searchBar: some View {
        HStack(spacing: smallSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Place or address", text: $search.query)
                .focused($searchFocused)
                .onChange(of: searchFocused) { _, focused in
                    if focused {
                        setDrawerDetent(.expanded)
                        planningLocation.request()
                    }
                }
                .submitLabel(.search)
                .onSubmit { searchFocused = false; runSearch(); setDrawerDetent(.half) }
                .onChange(of: search.query) { _, _ in
                    search.search(near: searchOrigin, searchCenter: searchCenter)
                    if drawerDetent == .collapsed, !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        setDrawerDetent(.half)
                    }
                }
            if search.isLoading { ProgressView().controlSize(.small) }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, searchBarPadding)
        .frame(minHeight: touchTarget)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: Capsule())
    }

    private var planningLocationButton: some View {
        Button {
            following = true
            planningLocation.request(refresh: true)
            if let searchOrigin {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                    camera = .camera(MapCamera(centerCoordinate: searchOrigin.coordinate, distance: 3_000))
                }
            }
        } label: {
            Image(systemName: following ? "location.fill" : "location")
                .frame(width: touchTarget, height: touchTarget)
                .accessibilityHidden(true)
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Use my location")
        .accessibilityHint("Uses your current location for nearby places and distances")
    }

    private func setDrawerDetent(_ detent: DrawerDetent) {
        let animation: Animation = reduceMotion ? .easeOut(duration: quickAnimationDuration) : .spring(response: springResponse, dampingFraction: springDamping)
        withAnimation(animation) { drawerDetent = detent }
    }

    private func selectDestination(_ destination: Destination) {
        guard selectedPlace?.id != destination.id else { return }
        searchFocused = false
        search.select(destination)
        navigation.end()
        withAnimation(driveTransitionAnimation) {
            selectedPlace = destination
            following = false
            camera = .rect(PlaceMapFocus.rect(for: destination.point))
        }
        previewSelectedDestination()
        setDrawerDetent(.half)
    }

    private func previewSelectedDestination(force: Bool = false) {
        guard let selectedPlace, !model.isDriving else { return }
        if routePlanner.customOrigin == nil, searchOrigin == nil { planningLocation.request(refresh: force) }
        routePlanner.preview(selectedPlace, currentLocation: searchOrigin, navigation: navigation, endpoint: apiURL,
                             preferences: RoutePreferences(avoidTolls: avoidTolls, avoidHighways: avoidHighways), force: force)
    }

    private func focusRoute(_ route: DrivingRoute, viewport: CGSize) {
        following = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
            camera = .rect(PlaceMapFocus.routeRect(for: route.geometry, viewport: viewport))
        }
    }

    private func editRouteOrigin() {
        originSearch.cancel()
        originSearch.clearSelection()
        originSearch.query = ""
        originSearch.search(near: searchOrigin, searchCenter: searchCenter)
        routePlanner.isEditingOrigin = true
        setDrawerDetent(.expanded)
    }

    private func chooseRouteOrigin(_ place: Destination) {
        originSearch.cancel()
        originSearch.clearSelection()
        recents.add(place)
        routePlanner.origin = .place(place)
        routePlanner.isEditingOrigin = false
        previewSelectedDestination()
        setDrawerDetent(.half)
    }

    private func useCurrentRouteOrigin() {
        originSearch.cancel()
        originSearch.clearSelection()
        routePlanner.origin = .myLocation
        routePlanner.isEditingOrigin = false
        previewSelectedDestination()
        setDrawerDetent(.half)
    }

    private func cancelOriginSearch() {
        originSearch.cancel()
        originSearch.clearSelection()
        routePlanner.isEditingOrigin = false
        setDrawerDetent(.half)
    }

    private func editRouteDestination() {
        navigation.end()
        search.clearSelection()
        selectedPlace = nil
        setDrawerDetent(.expanded)
        searchFocused = true
    }

    private func closeDestination() {
        search.clearSelection()
        navigation.end()
        originSearch.cancel()
        originSearch.clearSelection()
        routePlanner.clearTrip()
        withAnimation(driveTransitionAnimation) { selectedPlace = nil }
        setDrawerDetent(.half)
    }

    private func driveToSelectedPlace() {
        guard let selectedPlace else { return }
        let objective = navigation.selectedRoute?.objective ?? routePlanner.profile
        // A custom planning origin must never masquerade as the physical driving location.
        if routePlanner.customOrigin == nil, let route = navigation.selectedRoute {
            navigation.select(route)
        } else {
            navigation.preview(selectedPlace, fix: nil, endpoint: apiURL,
                               preferences: RoutePreferences(avoidTolls: avoidTolls, avoidHighways: avoidHighways),
                               objective: objective, maxExtraDurationPercent: routePlanner.maxExtraDurationPercent)
        }
        routePlanner.origin = .myLocation
        beginDriving()
        drivingSession.requestNavigationStart()
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Speed display") {
                    Picker("Units", selection: $unit) {
                        ForEach(SpeedUnit.allCases) { unit in Text(unit.symbol).tag(unit) }
                    }.pickerStyle(.segmented)
                }
                Section("Routing") {
                    Toggle("Prefer avoiding tolls", isOn: $avoidTolls)
                    Toggle("Prefer avoiding motorways", isOn: $avoidHighways)
                    Text("Avoidance is a preference, not a guarantee. Route availability depends on map coverage.")
                        .font(.caption)
                }
                Section {
                    TextField("API base URL", text: $apiURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("RoadScout API base URL")
                    Button("Use default server") { apiURL = AppConfiguration.routingAPIBaseURL }
                } header: {
                    Text("RoadScout API")
                } footer: {
                    Text("Default: \(AppConfiguration.routingAPIBaseURL). Enter the base URL without /v1/routes. Used for routes, cameras and weather; changes apply to subsequent requests.")
                }
                Section("Cameras") {
                    Toggle("Show cameras and warnings", isOn: $camerasEnabled)
                    Toggle("Camera audio warnings", isOn: $cameraAudioEnabled).disabled(!camerasEnabled)
                    Picker("Warn ahead", selection: $cameraWarningDistance) {
                        ForEach([300.0, 500.0, 800.0, 1000.0, 1500.0], id: \.self) { meters in
                            Text(PlaceDistanceFormatter.string(meters, unit: unit)).tag(meters)
                        }
                    }
                    .disabled(!camerasEnabled)
                    Text("Average-speed sections have purple markers/lines. Average-speed measurement is not yet implemented. Audio follows the driving sound control.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Roof Down weather") {
                    Toggle("Show Roof Down weather", isOn: $showRoofDownWeather)
                    WeatherAttribution()
                    Text("Route samples and their estimated passage times are sent through your RoadScout server to Open-Meteo. Weather is shown only while planning.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Live traffic") {
                    Toggle("Show traffic and route suggestions", isOn: $showLiveTraffic)
                    if let status = traffic.status { Text(status).font(.caption) }
                    if let map = traffic.map {
                        Text(map.routingEnabled ? "Traffic-aware routing enabled" : "Traffic-aware routing is not enabled on this server.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(map.sources, id: \.id) { source in
                            Text("\(source.countries.joined(separator: ", ")) · \(source.attribution)").font(.caption)
                            if source.stale { Text("Source may be stale or partial.").font(.caption).foregroundStyle(.secondary) }
                            if let message = source.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        }
                        if map.truncated { Text("Map traffic is partial at this zoom level.").font(.caption) }
                    }
                    Text("Traffic-aware routes depend on server support and measured road coverage. Faster routes use a 15-second Yes countdown; No keeps your route. Suggestions cancel when the app is hidden.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CameraDataSettings(metadata: cameraAlerts.metadata, cached: cameraAlerts.isUsingCache,
                                   status: cameraAlerts.statusMessage)
                Section {
                    Toggle("Include experimental routing", isOn: $includeExperimentalRouting)
                    if routingCatalog.source == .fallback, let message = routingCatalog.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Route styles and time limits are provided by the routing server. Experimental styles may change and can be turned off here.")
                            .font(.caption)
                    }
                } header: {
                    Text("Route styles")
                }
                Section("Location & privacy") {
                    Text("Search requests a single foreground location. A live drive continues navigation and camera warnings when the screen is locked or another app is open, until you tap End. The system shows its background location indicator. Motion sensors and map animation pause while backgrounded. Place search uses Apple services; routes and camera queries use your RoadScout server. No analytics or trip recording.")
                    Text("Location permission and iOS background scheduling are required. Force-quitting or system termination stops the session; RoadScout does not restart tracking automatically. Demo sessions stop in the background.")
                    Text("Route ETA is an estimate. Live traffic depends on server support and road coverage.")
                }
                Section {
                    NavigationLink("Demo & Testing") {
                        DemoTestingView(isDemo: source != .live,
                                        startFreeDrive: { startDemo(.replay) },
                                        startNavigation: { startDemo(.navigationReplay) },
                                        exitDemo: { exitDemo(); showingSettings = false })
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingSettings = false }
            } }
        }
    }


    private func runSearch() {
        search.search(near: searchOrigin, searchCenter: searchCenter)
        if drawerDetent == .collapsed { setDrawerDetent(.half) }
    }

    private func exitDemo() {
        cameraAlerts.clear()
        drivingSpeech.cancelCameraWarnings()
        routePlanner.clearTrip()
        originSearch.cancel()
        originSearch.clearSelection()
        selectedPlace = nil
        search.clearSelection()
        model.stop()
        navigation.end()
        search.cancel()
        search.query = ""
        source = .live
        following = true
        camera = .automatic
        setDrawerDetent(.collapsed)
    }

    private func startDemo(_ demoSource: DrivingSource) {
        exitDemo()
        do {
            planningCamera = lastMapCamera.map(MapCameraPosition.camera) ?? camera
            if demoSource == .navigationReplay { try navigation.loadDemo() }
            source = demoSource
            showingSettings = false
            model.start(source: demoSource)
            if demoSource == .navigationReplay { drivingSession.requestNavigationStart() }
        } catch {
            exitDemo()
            showingSettings = false
            demoError = error.localizedDescription
        }
    }

}

private enum DrawerDetent {
    case collapsed, half, expanded

    var presentationDetent: PresentationDetent {
        switch self {
        case .collapsed: .height(76)
        case .half: .medium
        case .expanded: .large
        }
    }

    init(presentationDetent: PresentationDetent) {
        if presentationDetent == .large { self = .expanded }
        else if presentationDetent == .medium { self = .half }
        else { self = .collapsed }
    }
}

#Preview {
    ContentView()
}

#Preview("ContentView Landscape", traits: .landscapeLeft) {
    ContentView()
}

#Preview("ContentView Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}

#Preview("Drawer · medium") {
    ContentView(initialDrawerDetent: .medium)
}

#Preview("Drawer · expanded") {
    ContentView(initialDrawerDetent: .large)
}

#if DEBUG
/// Fixed input for canvas inspection: no GPS, network requests, or replay playback.
@MainActor
private final class DrivingPreviewLocationProvider: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    let timestamp: Date
    let speed: Double
    let point: GeoPoint
    let course: Double

    init(timestamp: Date, speed: Double = 13.89, point: GeoPoint = GeoPoint(latitude: 52.09, longitude: 5.12), course: Double = 45) {
        self.timestamp = timestamp; self.speed = speed; self.point = point; self.course = course
    }

    func start() {
        onEvent?(.access(.authorized))
        onEvent?(.fix(LocationFix(latitude: point.latitude, longitude: point.longitude,
                                  speed: speed, speedAccuracy: 0.5,
                                  horizontalAccuracy: 5, course: course,
                                  timestamp: timestamp)))
    }

    func stop() { }
}

@MainActor
private func drivingPreviewModel() -> DrivingModel {
    let timestamp = Date()
    let model = DrivingModel(makeProvider: { _ in
        DrivingPreviewLocationProvider(timestamp: timestamp)
    }, now: { timestamp })
    model.start(source: .replay)
    return model
}

#Preview("Driving · simulated 50 km/h") {
    ContentView(model: drivingPreviewModel())
}

#Preview("Driving · landscape", traits: .landscapeLeft) {
    ContentView(model: drivingPreviewModel())
}

#Preview("Driving · dark") {
    ContentView(model: drivingPreviewModel())
        .preferredColorScheme(.dark)
}

@MainActor private final class DashboardPreviewAudio: AudioAnnouncing {
    func speak(_ text: String, language: String) { }
    func stop() { }
}

extension ContentView {
    @MainActor static func navigationDashboardPreview(unavailableSpeed: Bool = false, panned: Bool = false, progressPreview: Bool = false) -> ContentView {
        let timestamp = Date()
        let driving = DrivingModel(makeProvider: { _ in
            DrivingPreviewLocationProvider(timestamp: timestamp, speed: unavailableSpeed ? -1 : (progressPreview ? 0 : 13.89),
                point: GeoPoint(latitude: progressPreview ? 52.0907 : 52.09, longitude: 5.12), course: progressPreview ? 0 : 45)
        }, now: { timestamp })
        driving.start(source: .navigationReplay)
        let navigation = NavigationModel(audio: DashboardPreviewAudio(), now: { timestamp })
        try? navigation.loadDemo()
        navigation.start(fix: driving.fix)
        var view = ContentView(model: driving, navigationModel: navigation, initialFollowing: !(panned || progressPreview))
        if progressPreview, let route = navigation.selectedRoute {
            let line = MKPolyline(coordinates: route.geometry.map(\.coordinate), count: route.geometry.count)
            view._camera = State(initialValue: .rect(line.boundingMapRect.insetBy(dx: -1800, dy: -1800)))
        }
        return view
    }
}

#Preview("Driving · navigation bottom card") { ContentView.navigationDashboardPreview() }
#Preview("Driving · completed route faded") { ContentView.navigationDashboardPreview(progressPreview: true) }
#Preview("Driving · unknown speed, no banner") { ContentView.navigationDashboardPreview(unavailableSpeed: true) }
#Preview("Driving · panned, recenter above card") { ContentView.navigationDashboardPreview(panned: true) }
#Preview("Driving · navigation landscape", traits: .landscapeLeft) { ContentView.navigationDashboardPreview() }
#endif
