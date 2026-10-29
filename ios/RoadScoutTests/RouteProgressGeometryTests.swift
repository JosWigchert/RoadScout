import Foundation
import Testing
@testable import RoadScout

private func progressRoute(_ points: [GeoPoint] = [
    GeoPoint(latitude: 52, longitude: 5),
    GeoPoint(latitude: 52.001, longitude: 5),
    GeoPoint(latitude: 52.001, longitude: 5.001)
]) throws -> DrivingRoute {
    try DrivingRoute(geometry: points, distanceMeters: 50_000, durationSeconds: 600,
        maneuvers: [RouteManeuver(id: "depart", instruction: "Drive", spokenInstruction: "Drive",
            beginIndex: 0, endIndex: points.count - 1, seconds: 600, type: "depart", modifier: "straight")])
}

struct RouteProgressGeometryTests {
    @Test func planningAndInvalidProgressKeepFullRouteProminent() throws {
        let route = try progressRoute()
        let values: [Double?] = [nil, -1, 0, .nan, .infinity]
        for progress in values {
            let shape = RouteProgressGeometry(route: route, traveledMeters: progress)
            #expect(shape.completed.isEmpty)
            #expect(shape.remaining == route.geometry)
        }
    }

    @Test func splitsWithinSegmentAtSharedInterpolatedCoordinate() throws {
        let route = try progressRoute()
        let shape = RouteProgressGeometry(route: route, traveledMeters: route.cumulativeMeters[1] / 2)
        let cut = try #require(shape.completed.last)
        #expect(abs(cut.latitude - 52.0005) < 1e-9)
        #expect(abs(cut.longitude - 5) < 1e-9)
        #expect(shape.remaining.first == cut)
        #expect(shape.completed.first == route.geometry.first)
        #expect(shape.remaining.last == route.geometry.last)
        #expect(shape.completed.count == 2)
        #expect(shape.remaining.count == 3)
    }

    @Test func exactVertexUsesShapeArclengthRatherThanEngineSummaryDistance() throws {
        let route = try progressRoute()
        #expect(route.distanceMeters > route.cumulativeMeters.last! * 10)
        let shape = RouteProgressGeometry(route: route, traveledMeters: route.cumulativeMeters[1])
        #expect(shape.completed == Array(route.geometry[0...1]))
        #expect(shape.remaining == Array(route.geometry[1...2]))
    }

    @Test func arrivalAndOvershootCompleteTheEntireShape() throws {
        let route = try progressRoute()
        for distance in [route.cumulativeMeters.last!, route.cumulativeMeters.last! + 100] {
            let shape = RouteProgressGeometry(route: route, traveledMeters: distance)
            #expect(shape.completed == route.geometry)
            #expect(shape.remaining.isEmpty)
        }
    }

    @Test func datelineCutUsesShortCrossingAndRerouteStartsUnfaded() throws {
        let route = try progressRoute([GeoPoint(latitude: 0, longitude: 179.99), GeoPoint(latitude: 0, longitude: -179.99)])
        let shape = RouteProgressGeometry(route: route, traveledMeters: route.cumulativeMeters.last! / 2)
        let cut = try #require(shape.completed.last)
        #expect(abs(abs(cut.longitude) - 180) < 1e-8)
        #expect(cut.isValid)
        #expect(shape.remaining.first == cut)
        let replacement = try progressRoute()
        let reset = RouteProgressGeometry(route: replacement, traveledMeters: nil)
        #expect(reset.completed.isEmpty)
        #expect(reset.remaining == replacement.geometry)
    }
}
