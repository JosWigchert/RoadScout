import Foundation

enum Polyline6 {
    static func decode(_ encoded: String) throws -> [GeoPoint] {
        guard encoded.utf8.count <= 2_000_000 else { throw RoutingError.invalidResponse }
        let bytes = Array(encoded.utf8)
        var index = 0
        func component() throws -> Int64 {
            var value: Int64 = 0
            var shift = 0
            while index < bytes.count, shift <= 30 {
                let byte = bytes[index]
                index += 1
                guard (63...126).contains(byte) else { throw RoutingError.invalidResponse }
                let chunk = Int64(byte - 63)
                value |= (chunk & 31) << shift
                if chunk < 32 { return value & 1 == 0 ? value >> 1 : ~(value >> 1) }
                shift += 5
            }
            throw RoutingError.invalidResponse
        }
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var points: [GeoPoint] = []
        while index < bytes.count {
            latitude += try component()
            longitude += try component()
            let point = GeoPoint(latitude: Double(latitude) / 1e6, longitude: Double(longitude) / 1e6)
            guard point.isValid, points.count < 100_000 else { throw RoutingError.invalidResponse }
            points.append(point)
        }
        guard points.count >= 2 else { throw RoutingError.invalidResponse }
        return points
    }
}
