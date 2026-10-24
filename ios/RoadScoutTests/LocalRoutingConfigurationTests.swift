import Foundation
import Testing
@testable import RoadScout

struct LocalRoutingConfigurationTests {
    @Test func defaultAndSavedEndpointMigrationFollowBuildConfiguration() {
        #expect(AppConfiguration.migratedRoutingAPIURL("") == AppConfiguration.routingAPIBaseURL)
        #expect(AppConfiguration.migratedRoutingAPIURL("https://custom.example.com") == "https://custom.example.com")
        #if DEBUG
        #expect(AppConfiguration.routingAPIBaseURL == AppConfiguration.localTestingRoutingAPIBaseURL)
        #expect(AppConfiguration.migratedRoutingAPIURL(AppConfiguration.productionRoutingAPIBaseURL) == AppConfiguration.localTestingRoutingAPIBaseURL)
        #else
        #expect(AppConfiguration.routingAPIBaseURL == AppConfiguration.productionRoutingAPIBaseURL)
        #expect(AppConfiguration.migratedRoutingAPIURL(AppConfiguration.localTestingRoutingAPIBaseURL) == AppConfiguration.productionRoutingAPIBaseURL)
        #endif
    }

    @Test func onlyConfiguredDebugHostAndPortAllowHTTP() throws {
        #if DEBUG
        let provider = try RoadScoutRoutingProvider(baseURL: AppConfiguration.localTestingRoutingAPIBaseURL)
        #expect(provider.endpoint.absoluteString == AppConfiguration.localTestingRoutingAPIBaseURL + "/v1/routes")
        #else
        #expect(throws: RoutingError.self) { try RoadScoutRoutingProvider(baseURL: AppConfiguration.localTestingRoutingAPIBaseURL) }
        #endif
        for url in ["http://example.com:8080", "http://192.168.1.111:8080", "http://192.168.1.157:8002",
                    "http://192.168.1.157.evil.example:8080", "http://127.0.0.1:8080"] {
            #expect(throws: RoutingError.self) { try RoadScoutRoutingProvider(baseURL: url) }
        }
    }

    @Test func redirectsCannotDowngradeHTTPSOrSwitchToAnotherHTTPHost() throws {
        let https = try #require(URL(string: AppConfiguration.productionRoutingAPIBaseURL))
        let local = try #require(URL(string: AppConfiguration.localTestingRoutingAPIBaseURL))
        let other = try #require(URL(string: "http://192.168.1.111:8080"))
        #expect(!AppConfiguration.allowsRoutingResponse(local, for: https))
        #expect(!AppConfiguration.allowsRoutingResponse(other, for: local))
        #expect(AppConfiguration.allowsRoutingResponse(https, for: https))
        #if DEBUG
        #expect(AppConfiguration.allowsRoutingResponse(local, for: local))
        #else
        #expect(!AppConfiguration.allowsRoutingResponse(local, for: local))
        #endif
    }

    #if DEBUG
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROADSCOUT_LAN_SMOKE"] == "1"))
    func optInLiveCameraDatasetUsesTheSingleGoEndpoint() async throws {
        let response = try await CameraClient().fetch(bounds: CameraBounds(south: 50.7, west: 3.1, north: 53.7, east: 7.3),
            route: nil, endpoint: AppConfiguration.localTestingRoutingAPIBaseURL)
        #expect(!response.dataset.version.isEmpty)
        #expect(response.dataset.coverage == "NL")
        #expect(response.dataset.lastCheckedAt != nil)
        #expect(!response.cameras.isEmpty)
        #expect(!response.averageSpeedZones.isEmpty)
        #expect(response.averageSpeedZones.filter(\.geometryVerified).allSatisfy { $0.geometry.count >= 2 && $0.start != nil && $0.end != nil })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROADSCOUT_EXPERIMENTAL_SMOKE"] == "1"))
    func optInExperimentalLANRouteUsesMetadataAndDetourBudget() async throws {
        let provider = try RoadScoutRoutingProvider(baseURL: AppConfiguration.localTestingRoutingAPIBaseURL)
        let routes = try await provider.routes(for: RouteRequest(origin: GeoPoint(latitude: 52.0907, longitude: 5.1214),
            destination: GeoPoint(latitude: 52.1552, longitude: 5.3872), preferences: .init(),
            objective: .moreCorners, maxExtraDurationPercent: 30))
        let route = try #require(routes.first)
        let experiment = try #require(route.experiment)
        #expect(experiment.requestedObjective == "more_corners")
        #expect(experiment.extraDurationPercent <= 30.0001)
        #expect(!route.maneuvers.flatMap(\.streetNames).isEmpty)
        if experiment.status == "improved" {
            #expect(route.objective == .moreCorners)
            #expect(experiment.bendCount > 0)
        } else {
            #expect(route.objective == .fastest)
            #expect(experiment.fallbackMessage != nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROADSCOUT_LAN_SMOKE"] == "1"))
    func optInLiveCapabilitiesCatalogUsesRealAppTransport() async throws {
        let capabilities = try await RoutingCapabilitiesClient().fetch(baseURL: AppConfiguration.localTestingRoutingAPIBaseURL)
        #expect(capabilities.routingOptions.first?.id == "fastest")
        #expect(capabilities.routingOptions.contains { $0.isExperimental && !$0.detourOptions.isEmpty })
        #expect(capabilities.detourOptions.contains(100))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROADSCOUT_LAN_SMOKE"] == "1"))
    func optInLiveLANRouteUsesRealAppTransport() async throws {
        let provider = try RoadScoutRoutingProvider(baseURL: AppConfiguration.localTestingRoutingAPIBaseURL)
        let routes = try await provider.routes(for: RouteRequest(origin: GeoPoint(latitude: 52.0907, longitude: 5.1214),
            destination: GeoPoint(latitude: 52.1552, longitude: 5.3872), preferences: .init()))
        #expect(!routes.isEmpty)
        #expect(routes.allSatisfy { $0.geometry.count > 2 && $0.geometry.allSatisfy(\.isValid) && !$0.maneuvers.isEmpty && $0.distanceMeters > 0 })
    }
    #endif
}
