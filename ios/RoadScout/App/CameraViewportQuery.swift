import Foundation

/// Quantized query bounds avoid a new cache entry/network request for every camera animation frame.
enum CameraViewportQuery {
    static func around(_ point: GeoPoint, radius: Double = 3_000) -> CameraBounds {
        let latitude = (point.latitude * 200).rounded() / 200
        let longitude = (point.longitude * 200).rounded() / 200
        let lat = max(1_000, radius) / 111_000
        let lon = lat / max(0.15, cos(latitude * .pi / 180))
        return CameraBounds(south: max(-90, latitude - lat), west: max(-180, longitude - lon),
                            north: min(90, latitude + lat), east: min(180, longitude + lon))
    }

    static func viewport(center: GeoPoint, latitudeDelta: Double, longitudeDelta: Double) -> CameraBounds {
        let lat = max(0.01, ceil(min(180, abs(latitudeDelta)) * 100) / 100)
        let lon = max(0.01, ceil(min(360, abs(longitudeDelta)) * 100) / 100)
        let latitude = (center.latitude * 200).rounded() / 200
        let longitude = (center.longitude * 200).rounded() / 200
        return CameraBounds(south: max(-90, latitude - lat / 2), west: max(-180, longitude - lon / 2),
                            north: min(90, latitude + lat / 2), east: min(180, longitude + lon / 2))
    }
}
