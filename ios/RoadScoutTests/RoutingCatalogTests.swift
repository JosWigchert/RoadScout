import Foundation
import Testing
@testable import RoadScout

private struct CatalogTransport: RoutingHTTPTransport {
    let data: Data
    let status: Int
    let failing: Bool
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if failing { throw URLError(.cannotConnectToHost) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func catalogData(_ json: String) -> Data { Data(json.utf8) }

@MainActor
struct RoutingCatalogTests {
    @Test func serverCatalogDrivesOptionsTitlesAndDetourBudgets() async throws {
        let json = """
        {"objectives":["fastest","scenic","more_corners"],
         "routingOptions":[
           {"id":"fastest","title":"Fastest","experimental":false,"detourOptions":[]},
           {"id":"scenic","title":"Scenic","experimental":true,"detourOptions":[15,30,50,85,100]},
           {"id":"more_corners","title":"More Corners","experimental":true,"detourOptions":[15,30,50,85,100]}],
         "detourOptions":[15,30,50,85,100]}
        """
        let catalog = RoutingCatalog(client: RoutingCapabilitiesClient(transport: CatalogTransport(data: catalogData(json), status: 200, failing: false)))
        catalog.load(endpoint: "https://routing.example.com")
        for _ in 0..<200 where catalog.source == .loading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(catalog.source == .server)
        #expect(catalog.visibleOptions(includeExperimental: true).map(\.id) == ["fastest", "scenic", "more_corners"])
        #expect(catalog.visibleOptions(includeExperimental: false).map(\.id) == ["fastest"])
        #expect(catalog.option(id: "scenic")?.detourOptions == [15, 30, 50, 85, 100])
    }

    @Test func missingRoutingOptionsFallsBackToObjectiveIdsAndKeepsFastest() async throws {
        let json = #"{"objectives":["scenic","more_corners"]}"#
        let catalog = RoutingCatalog(client: RoutingCapabilitiesClient(transport: CatalogTransport(data: catalogData(json), status: 200, failing: false)))
        catalog.load(endpoint: "https://routing.example.com")
        for _ in 0..<200 where catalog.source == .loading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(catalog.options.first?.id == "fastest")
        #expect(catalog.option(id: "scenic")?.isExperimental == true)
    }

    @Test func unreachableServerUsesFastestOnlyFallback() async throws {
        let catalog = RoutingCatalog(client: RoutingCapabilitiesClient(transport: CatalogTransport(data: Data(), status: 200, failing: true)))
        catalog.load(endpoint: "https://routing.example.com")
        for _ in 0..<200 where catalog.source == .loading { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(catalog.source == .fallback)
        #expect(catalog.visibleOptions(includeExperimental: true).map(\.id) == ["fastest"])
        #expect(catalog.message != nil)
    }
}
