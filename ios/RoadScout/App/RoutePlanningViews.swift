import SwiftUI
import MapKit

struct RoutePlanningView: View {
    let destination: Destination
    @Bindable var planner: RoutePlanningModel
    let navigation: NavigationModel
    let unit: SpeedUnit
    let locationMessage: String?
    let editOrigin: () -> Void
    let editDestination: () -> Void
    let retry: () -> Void
    let drive: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Directions").font(.title2.bold())
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                    .buttonStyle(MapIconButtonStyle())
                    .accessibilityLabel("Close directions")
            }

            HStack {
                if planner.canChooseStyle {
                    Menu {
                        Picker("Route style", selection: $planner.profile) {
                            ForEach(planner.options) { option in Text(option.title).tag(option.profile) }
                        }
                    } label: {
                        Label(planner.selectedOption?.title ?? planner.profile.fallbackTitle, systemImage: "car.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                } else {
                    Label(planner.selectedOption?.title ?? planner.profile.fallbackTitle, systemImage: "car.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                }
                Spacer()
                if planner.usesDetourBudget {
                    Menu {
                        Picker("Maximum extra travel time", selection: $planner.maxExtraDurationPercent) {
                            ForEach(planner.detourOptions, id: \.self) { value in Text("Up to \(value)% longer").tag(value) }
                        }
                    } label: {
                        Label("+\(planner.maxExtraDurationPercent)% max", systemImage: "clock").font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                Button(action: editOrigin) {
                    endpointRow(title: planner.originTitle, subtitle: String(localized: "From · tap to change"), symbol: "location.fill", color: .gray)
                }
                Divider().padding(.leading, 64)
                Button(action: editDestination) {
                    endpointRow(title: destination.name, subtitle: String(localized: "To · tap to change"),
                                symbol: destination.symbol ?? "mappin", color: PlaceCategoryStyle.color(for: destination.symbol))
                }
            }
            .buttonStyle(.plain)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if planner.selectedOption?.isExperimental == true {
                        Text("Experimental route style provided by the routing server. Results are estimates and may change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if navigation.isLoading {
                        ProgressView("Finding the fastest route…").padding(.vertical, 12)
                    }
                    if let message = locationMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if let message = navigation.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if let selected = navigation.selectedRoute {
                        if let message = selected.experiment?.fallbackMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                        ForEach(navigation.routes) { route in
                            routeOption(route, selected: route.id == selected.id)
                        }
                        Text("Arrival times are estimates and do not include live traffic.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(selected.attribution).font(.caption2).foregroundStyle(.secondary)
                    } else if !navigation.isLoading {
                        Button(action: retry) {
                            Label("Calculate route", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(.primary)
    }

    private func endpointRow(title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(color.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func routeOption(_ route: DrivingRoute, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                navigation.select(route)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(max(1, Int(ceil(route.durationSeconds / 60)))) min").font(.title2.bold())
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    Text(RoutePresentation.title(for: route, in: navigation.routes))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let via = RoutePresentation.corridorLabel(for: route), via != RoutePresentation.title(for: route, in: navigation.routes) {
                        Text(via).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(Date().addingTimeInterval(route.durationSeconds).formatted(date: .omitted, time: .shortened)) ETA · \(PlaceDistanceFormatter.string(route.distanceMeters, unit: unit))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let experiment = route.experiment, route.objective?.isExperimental == true {
                        Text("≈\(experiment.bendCount) qualifying bends · \(Int(experiment.countrysideShare * 100))% eligible country roads · +\(Int(experiment.extraDurationPercent.rounded()))% time")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(RoutePresentation.title(for: route, in: navigation.routes)), \(max(1, Int(ceil(route.durationSeconds / 60)))) minutes")
            if selected {
                Button(action: drive) {
                    Label("Drive", systemImage: "arrow.up")
                        .font(.headline).frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .background(selected ? Color.primary.opacity(0.09) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? Color.primary.opacity(0.2) : .clear, lineWidth: 1))
    }
}

struct RouteOriginSearchView: View {
    @Bindable var search: PlaceSearchModel
    let currentLocation: GeoPoint?
    let mapCenter: GeoPoint?
    let unit: SpeedUnit
    let useMyLocation: () -> Void
    let choose: (Destination) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Starting point").font(.title2.bold())
                Spacer()
                Button("Cancel", action: cancel).foregroundStyle(.secondary).frame(minHeight: 44)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for a starting point", text: $search.query)
                    .focused($focused).submitLabel(.search)
                    .onSubmit { focused = false; search.search(near: currentLocation, searchCenter: mapCenter) }
                    .onChange(of: search.query) { _, _ in search.search(near: currentLocation, searchCenter: mapCenter) }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44)
                    }
                        .accessibilityLabel("Clear starting point search")
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 48)
            .background(.quaternary, in: Capsule())

            ScrollView {
                VStack(spacing: 12) {
                    Button(action: useMyLocation) {
                        Label("My location", systemImage: "location.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, 16)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    if search.isLoading { ProgressView("Searching places…") }
                    if let message = search.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        ForEach(Array(search.completions.enumerated()), id: \.offset) { _, completion in
                            Button {
                                if completion.subtitle.isEmpty {
                                    search.query = completion.title
                                    search.search(near: currentLocation, searchCenter: mapCenter)
                                } else {
                                    search.selectCompletion(completion, near: currentLocation, searchCenter: mapCenter)
                                }
                            } label: { PlaceSuggestionRow(title: completion.title, subtitle: completion.subtitle) }
                            Divider().padding(.leading, 72)
                        }
                        let values = search.query.isEmpty
                            ? PlaceProximity.updated(search.recents.items, origin: currentLocation, order: .relevance)
                            : search.results
                        ForEach(Array(values.enumerated()), id: \.element.id) { index, place in
                            Button { choose(place) } label: {
                                PlaceResultRow(destination: place,
                                    distance: currentLocation.map { PlaceDistanceFormatter.string($0.distance(to: place.point), unit: unit) })
                            }
                            if index < values.count - 1 { Divider().padding(.leading, 72) }
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 22))
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onChange(of: search.selectedDestination) { _, value in if let value { choose(value) } }
        .onChange(of: currentLocation) { _, value in search.updateOrigin(value) }
    }
}
