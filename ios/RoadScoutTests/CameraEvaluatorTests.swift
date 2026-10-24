import Foundation
import Testing
@testable import RoadScout

struct CameraEvaluatorTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func point(_ meters: Double, east: Double = 0) -> GeoPoint {
        .init(latitude: 52 + meters / 111_195, longitude: 5 + east / 68_458)
    }
    func fix(_ meters: Double = 0, east: Double = 0, course: Double = 0) -> LocationFix {
        let p = point(meters, east: east)
        return .init(latitude: p.latitude, longitude: p.longitude, speed: 10, speedAccuracy: 1,
                     horizontalAccuracy: 3, course: course, timestamp: now)
    }
    func camera(at meters: Double = 200, direction: Double? = 0, east: Double = 0) -> CameraRecord {
        .init(id: "osm:node:1", coordinate: point(meters, east: east), kind: "fixed", directionDegrees: direction,
              roadGeometry: [point(-200, east: east), point(600, east: east)], roadWayIDs: [1],
              association: "on_way", sourceIDs: ["osm:node:1"], status: "mapped")
    }
    func evaluate(_ evaluator: inout CameraAlertEvaluator, camera: CameraRecord, fix: LocationFix? = nil,
                  heading: Double = 0) -> CameraWarning? {
        evaluator.consume(cameras: [camera], zones: [], fix: fix ?? self.fix(), heading: heading,
                          route: nil, progress: nil, isDriving: true, settings: .init(), now: now)
    }

    @Test func aheadAndPassDedupe() {
        var e = CameraAlertEvaluator()
        #expect(evaluate(&e, camera: camera())?.confident == true)
        #expect(evaluate(&e, camera: camera()) == nil)
        #expect(e.alert?.confident == true)
        #expect(evaluate(&e, camera: camera(), fix: fix(1000)) == nil)
        #expect(evaluate(&e, camera: camera()) != nil)
    }
    @Test func behindOppositeAndParallelSuppressSpeech() {
        for c in [camera(at: -200), camera(direction: 180), camera(east: 25)] {
            var e = CameraAlertEvaluator()
            #expect(evaluate(&e, camera: c) == nil)
            #expect(e.alert?.confident != true)
        }
    }
    @Test func missingDirectionAndLegacyAreVisualOnly() {
        var c = camera(direction: nil), e = CameraAlertEvaluator()
        #expect(evaluate(&e, camera: c) == nil)
        #expect(e.alert?.title == "Mapped camera nearby")
        c.roadGeometry = nil
        #expect(evaluate(&e, camera: c) == nil)
        #expect(e.alert?.confident == false)
    }
    @Test func ambiguousCrossingRoadAndMutedPass() {
        var c = camera(), e = CameraAlertEvaluator()
        c.roadGeometry = [point(-100), point(400), point(400, east: 100), point(-100, east: -25)]
        #expect(evaluate(&e, camera: c) == nil)
        #expect(e.alert?.confident != true)
        e.reset()
        var settings = CameraWarningSettings(); settings.audioEnabled = false
        #expect(e.consume(cameras: [camera()], zones: [], fix: fix(), heading: 0,
                          route: nil, progress: nil, isDriving: true, settings: settings, now: now) == nil)
        #expect(e.alert?.confident == true)
        #expect(evaluate(&e, camera: camera()) == nil)
    }
    @Test func unusableFixDoesNotAdvancePass() {
        var e = CameraAlertEvaluator(), f = fix()
        f.timestamp = now.addingTimeInterval(-10)
        #expect(evaluate(&e, camera: camera(), fix: f) == nil)
        #expect(e.alert == nil)
        f = fix(); f.speed = 1
        #expect(evaluate(&e, camera: camera(), fix: f) == nil)
        f = fix(); f.horizontalAccuracy = 16
        #expect(evaluate(&e, camera: camera(), fix: f) == nil)
        #expect(evaluate(&e, camera: camera(), heading: 180) == nil)
        #expect(evaluate(&e, camera: camera()) != nil)
    }
    @Test func routeUsesArclengthAndConfirmedDirection() throws {
        let route = try DrivingRoute(geometry: [point(-200), point(1000)], distanceMeters: 5000, durationSeconds: 100,
                                     maneuvers: [.init(id: "m", instruction: "Go", spokenInstruction: "Go", beginIndex: 0, endIndex: 1, seconds: 100, type: "start", modifier: "")])
        let progress = NavigationProgress(traveledMeters: 500, remainingMeters: 4500, remainingSeconds: 90,
                                          maneuverIndex: 0, maneuverDistance: 100, offRoute: false, arrived: false)
        var c = camera(), e = CameraAlertEvaluator()
        c.routeDistanceMeters = 700; c.routeMatch = "confirmed"
        func run(valid: Bool = true) -> CameraWarning? {
            e.consume(cameras: [c], zones: [], fix: fix(), heading: 0, route: route, progress: progress,
                      routeEvidenceValid: valid, isDriving: true, settings: .init(), now: now)
        }
        #expect(run()?.distanceMeters == 200)
        e.reset(); c.routeMatch = "nearby"
        #expect(run() == nil); #expect(e.alert?.confident == false)
        e.reset(); c.routeMatch = "confirmed"
        #expect(run(valid: false) == nil)
        c.routeDistanceMeters = 400
        #expect(run() == nil); #expect(e.alert == nil)
    }
    @Test func verifiedZoneEntryInsideExit() {
        var e = CameraAlertEvaluator()
        var zone = AverageSpeedZone(id: "z", start: point(100), end: point(400),
                                    geometry: [point(100), point(400)], geometryVerified: true,
                                    directionDegrees: 0, sourceIDs: ["z"], status: "mapped")
        func run(_ meters: Double) -> CameraWarning? {
            e.consume(cameras: [], zones: [zone], fix: fix(meters), heading: 0, route: nil, progress: nil,
                      isDriving: true, settings: .init(), now: now)
        }
        #expect(run(95)?.isAverageZone == true)
        #expect(run(95) == nil)
        #expect(run(200) == nil); #expect(e.alert?.isInsideZone == true)
        #expect(run(400) == nil); #expect(e.alert?.title == "Mapped average-speed zone ends")
        zone.geometryVerified = false
        #expect(run(200) == nil); #expect(e.alert == nil)
    }

    @Test func confirmedCameraAroundBendUsesCameraRouteTangent() throws {
        let geometry = [point(0), point(0, east: 20), point(300, east: 20)]
        let route = try DrivingRoute(geometry: geometry, distanceMeters: 320, durationSeconds: 30,
                                    maneuvers: [.init(id: "m", instruction: "Go", spokenInstruction: "Go",
                                                     beginIndex: 0, endIndex: 2, seconds: 30, type: "start", modifier: "")])
        let progress = NavigationProgress(traveledMeters: 10, remainingMeters: 310, remainingSeconds: 29,
                                          maneuverIndex: 0, maneuverDistance: 10, offRoute: false, arrived: false)
        var c = camera(at: 200, direction: 0, east: 20), e = CameraAlertEvaluator()
        c.routeDistanceMeters = route.cumulativeMeters[1] + point(0, east: 20).distance(to: c.coordinate)
        c.routeMatch = "confirmed"
        func run(course: Double = 90) -> CameraWarning? {
            e.consume(cameras: [c], zones: [], fix: fix(0, east: 10, course: course), heading: course,
                      route: route, progress: progress, isDriving: true, settings: .init(), now: now)
        }
        let warning = run()
        #expect(warning?.confident == true)
        #expect(abs((warning?.distanceMeters ?? 0) - (c.routeDistanceMeters! - 10)) < 0.001)
        #expect(run() == nil)
        e.reset(); c.directionDegrees = nil
        #expect(run() == nil); #expect(e.alert?.confident == false)
        e.reset(); c.directionDegrees = 180
        #expect(run() == nil); #expect(e.alert?.confident == false)
        e.reset(); c.directionDegrees = 0
        #expect(run(course: 270) == nil); #expect(e.alert == nil)
        // Free drive keeps its conservative current-heading cone.
        #expect(e.consume(cameras: [c], zones: [], fix: fix(0, east: 10, course: 90), heading: 90,
                          route: nil, progress: nil, isDriving: true, settings: .init(), now: now) == nil)
        #expect(e.alert == nil)
    }

    @Test func curvingZoneUsesLocalOrderedTangentInsideAndRejectsReverse() throws {
        let geometry = [point(0), point(200), point(200, east: 300)]
        let route = try DrivingRoute(geometry: geometry, distanceMeters: 500, durationSeconds: 50,
                                    maneuvers: [.init(id: "m", instruction: "Go", spokenInstruction: "Go",
                                                     beginIndex: 0, endIndex: 2, seconds: 50, type: "start", modifier: "")])
        let progress = NavigationProgress(traveledMeters: 300, remainingMeters: 200, remainingSeconds: 20,
                                          maneuverIndex: 0, maneuverDistance: 200, offRoute: false, arrived: false)
        var zone = AverageSpeedZone(id: "curve", geometry: geometry, geometryVerified: true,
                                    directionDegrees: 0, sourceIDs: ["curve"], status: "mapped",
                                    routeStartMeters: 0, routeEndMeters: route.cumulativeMeters.last, routeMatch: "confirmed")
        for navigation in [false, true] {
            var e = CameraAlertEvaluator()
            func run(course: Double) -> CameraWarning? {
                e.consume(cameras: [], zones: [zone], fix: fix(200, east: 100, course: course), heading: course,
                          route: navigation ? route : nil, progress: navigation ? progress : nil,
                          isDriving: true, settings: .init(), now: now)
            }
            #expect(run(course: 90) == nil) // Inside remains visual, without a new entry announcement.
            #expect(e.alert?.isInsideZone == true)
            #expect(e.alert?.confident == true)
            #expect(run(course: 270) == nil); #expect(e.alert == nil)
        }
        var e = CameraAlertEvaluator()
        zone.directionDegrees = 180
        #expect(e.consume(cameras: [], zones: [zone], fix: fix(-5), heading: 0, route: nil, progress: nil,
                          isDriving: true, settings: .init(), now: now) == nil)
        #expect(e.alert == nil) // Entry still checks the initial enforcement direction.
    }

    @Test func averageSpeedDeviceDoesNotCreateGenericCameraWarning() {
        var e = CameraAlertEvaluator(), device = camera(at: 100)
        device.kind = "average_speed"
        #expect(evaluate(&e, camera: device, fix: fix(95)) == nil)
        #expect(e.alert == nil)
        let zone = AverageSpeedZone(id: "zone", geometry: [point(100), point(400)], geometryVerified: true,
                                    directionDegrees: 0, sourceIDs: ["zone"], status: "mapped")
        let warning = e.consume(cameras: [device], zones: [zone], fix: fix(95), heading: 0,
                                route: nil, progress: nil, isDriving: true, settings: .init(), now: now)
        #expect(warning?.id == "zone:entry")
        #expect(warning?.isAverageZone == true)
    }
}
