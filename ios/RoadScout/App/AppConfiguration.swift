import Foundation

enum AppConfiguration {
    static let productionRoutingAPIBaseURL = "https://roadscout.joswigchert.nl"
    // Temporary owner-requested LAN test server. Release never permits this HTTP endpoint.
    static let localTestingRoutingAPIBaseURL = "http://192.168.1.157:8080"

    static var routingAPIBaseURL: String {
        productionRoutingAPIBaseURL
    }

    static func migratedRoutingAPIURL(_ savedValue: String) -> String {
        let saved = savedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return routingAPIBaseURL }
        #if DEBUG
        return saved
        #else
        return saved == localTestingRoutingAPIBaseURL ? productionRoutingAPIBaseURL : saved
        #endif
    }

    static func allowsRoutingURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG
        let local = URL(string: localTestingRoutingAPIBaseURL)!
        return url.scheme?.lowercased() == "http" && url.host == local.host && url.port == local.port
        #else
        return false
        #endif
    }

    static func allowsRoutingResponse(_ response: URL, for request: URL) -> Bool {
        guard allowsRoutingURL(response) else { return false }
        if response.scheme?.lowercased() == "http" {
            return request.scheme?.lowercased() == "http" && response.host == request.host && response.port == request.port
        }
        return true
    }
}
