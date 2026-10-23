import Foundation
import Testing
@testable import RoadScout

struct PlaceProximityTests {
    private let origin = GeoPoint(latitude: 52, longitude: 5)

    @Test func nearestFirstUsesCurrentPositionInsteadOfSavedDistances() {
        let far = Destination(name: "Far", distance: 1, coordinate: GeoPoint(latitude: 52.1, longitude: 5))
        let near = Destination(name: "Near", distance: 99_000, coordinate: GeoPoint(latitude: 52.001, longitude: 5))
        let sorted = PlaceProximity.updated([far, near], origin: origin)
        #expect(sorted.map(\.id) == [near.id, far.id])
        #expect((sorted[0].distance ?? 0) > 100)
        #expect((sorted[1].distance ?? 0) > 10_000)
        let moved = PlaceProximity.updated(sorted, origin: far.point)
        #expect(moved.first?.id == far.id)
        #expect(moved.first?.distance == 0)
    }

    @Test func missingLocationKeepsRelevanceAndRemovesObsoleteDistance() {
        let first = Destination(name: "First", distance: 200, coordinate: origin)
        let second = Destination(name: "Second", distance: 100, coordinate: origin)
        let results = PlaceProximity.updated([first, second], origin: nil)
        #expect(results.map(\.id) == [first.id, second.id])
        #expect(results.allSatisfy { $0.distance == nil })
    }

    @Test func equalDistancesAreStableAndBestMatchPreservesProviderOrder() {
        let first = Destination(name: "First", coordinate: origin)
        let second = Destination(name: "Second", coordinate: origin)
        #expect(PlaceProximity.updated([first, second], origin: origin).map(\.id) == [first.id, second.id])
        let far = Destination(name: "Best match", coordinate: GeoPoint(latitude: 53, longitude: 5))
        let relevant = PlaceProximity.updated([far, first], origin: origin, order: .relevance)
        #expect(relevant.first?.id == far.id)
        #expect(relevant.allSatisfy { $0.distance != nil })
    }

    @Test func invalidCoordinatesCannotProduceMisleadingDistancesOrMapSelections() {
        let valid = Destination(name: "Valid", coordinate: origin)
        let invalid = Destination(name: "Invalid", coordinate: GeoPoint(latitude: .nan, longitude: 5))
        let results = PlaceProximity.updated([invalid, valid], origin: GeoPoint(latitude: 100, longitude: 5))
        #expect(results.map(\.id) == [valid.id])
        #expect(results[0].distance == nil)
    }

    @Test func legacyRecentsDecodeAndContactsSurviveDistanceUpdates() throws {
        let legacy = Data(#"{"name":"Legacy","latitude":52,"longitude":5,"distance":1234}"#.utf8)
        let decoded = try JSONDecoder().decode(Destination.self, from: legacy)
        #expect(decoded.phoneNumber == nil)
        #expect(decoded.website == nil)
        let place = Destination(name: "Market", coordinate: origin, phoneNumber: "+31 20 123 4567",
                                website: URL(string: "https://example.com"))
        let updated = PlaceProximity.updated([place], origin: origin)[0]
        let roundTrip = try JSONDecoder().decode(Destination.self, from: JSONEncoder().encode(updated))
        #expect(roundTrip == updated)
        #expect(roundTrip.phoneNumber == place.phoneNumber)
        #expect(roundTrip.website == place.website)
    }
}

@MainActor private final class PlanningTestProvider: LocationProviding {
    var onEvent: ((LocationEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor struct PlanningLocationTests {
    @Test func locationIsRequestedOnlyOnDemandAndStopsAfterOneFix() {
        let provider = PlanningTestProvider()
        let now = sampleFix().timestamp
        let model = PlanningLocationModel(provider: provider, now: { now })
        #expect(provider.startCount == 0)
        model.request()
        model.request()
        #expect(provider.startCount == 1)
        provider.onEvent?(.fix(sampleFix()))
        #expect(!model.isRequesting)
        #expect(provider.stopCount == 1)
        #expect(model.currentPoint?.latitude == 52)
        model.request()
        #expect(provider.startCount == 1)
        model.request(refresh: true)
        #expect(provider.startCount == 2)
        model.stop(clearFix: true)
        #expect(model.currentPoint == nil)
    }

    @Test func denialAndLateCallbacksDoNotLeaveLocationOrLoadingState() {
        let provider = PlanningTestProvider()
        let model = PlanningLocationModel(provider: provider, now: { sampleFix().timestamp })
        model.request()
        let callback = provider.onEvent
        provider.onEvent?(.access(.denied))
        #expect(!model.isRequesting)
        #expect(model.message != nil)
        callback?(.fix(sampleFix()))
        #expect(model.currentPoint == nil)
    }

    @Test func coarsePlanningPositionIsNotUsedAsPreciseRoutingFixAndExpires() {
        let provider = PlanningTestProvider()
        var now = sampleFix().timestamp
        let model = PlanningLocationModel(provider: provider, now: { now })
        model.request()
        var fix = sampleFix()
        fix.horizontalAccuracy = 500
        provider.onEvent?(.fix(fix))
        #expect(model.currentPoint != nil)
        #expect(model.routingFix == nil)
        now = now.addingTimeInterval(301)
        #expect(model.currentPoint == nil)
        model.request()
        #expect(provider.startCount == 2)
        model.stop()
    }
}
