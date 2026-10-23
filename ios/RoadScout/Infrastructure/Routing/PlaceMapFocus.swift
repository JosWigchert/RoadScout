import MapKit

enum PlaceMapFocus {
    /// Fit geometry into the exposed upper map rather than behind the planning sheet.
    static func routeRect(for geometry: [GeoPoint], viewport: CGSize) -> MKMapRect {
        let points = geometry.filter(\.isValid).map { MKMapPoint($0.coordinate) }
        guard let first = points.first else { return .world }
        let width = max(320, viewport.width)
        let height = max(320, viewport.height)
        let topInset = min(100, height * 0.14)
        let visibleHeight = max(80, height * 0.40 - topInset)
        let visibleWidth = width - 48
        let worldWidth = MKMapRect.world.width
        var previousX = first.x
        let unwrapped = points.map { point -> MKMapPoint in
            var x = point.x
            while x - previousX > worldWidth / 2 { x -= worldWidth }
            while previousX - x > worldWidth / 2 { x += worldWidth }
            previousX = x
            return MKMapPoint(x: x, y: point.y)
        }
        let minX = unwrapped.map(\.x).min()!
        let maxX = unwrapped.map(\.x).max()!
        let minY = unwrapped.map(\.y).min()!
        let maxY = unwrapped.map(\.y).max()!
        let minimumExtent = 200 / MKMetersPerMapPointAtLatitude(min(85, max(-85, first.coordinate.latitude)))
        let scale = max(max(maxX - minX, minimumExtent) / visibleWidth,
                        max(maxY - minY, minimumExtent) / visibleHeight)
        return MKMapRect(x: (minX + maxX) / 2 - width * scale / 2,
                         y: (minY + maxY) / 2 - (topInset + visibleHeight / 2) * scale,
                         width: width * scale, height: height * scale)
    }

    static func labelPoint(on route: DrivingRoute, fraction: Double) -> GeoPoint {
        let target = (route.cumulativeMeters.last ?? 0) * min(1, max(0, fraction))
        for index in 1..<route.geometry.count where route.cumulativeMeters[index] >= target {
            let start = route.geometry[index - 1]
            let end = route.geometry[index]
            let length = route.cumulativeMeters[index] - route.cumulativeMeters[index - 1]
            let t = length > 0 ? (target - route.cumulativeMeters[index - 1]) / length : 0
            var longitudeDelta = end.longitude - start.longitude
            if longitudeDelta > 180 { longitudeDelta -= 360 }
            if longitudeDelta < -180 { longitudeDelta += 360 }
            let longitude = start.longitude + longitudeDelta * t
            return GeoPoint(latitude: start.latitude + (end.latitude - start.latitude) * t,
                            longitude: longitude > 180 ? longitude - 360 : (longitude < -180 ? longitude + 360 : longitude))
        }
        return route.geometry.last!
    }

    /// Leave space for the medium destination sheet: the pin sits in the exposed upper map.
    static func rect(for point: GeoPoint) -> MKMapRect {
        let pin = MKMapPoint(point.coordinate)
        let scale = 600 / MKMetersPerMapPointAtLatitude(point.latitude)
        return MKMapRect(x: pin.x - scale, y: pin.y - scale * 0.6,
                         width: scale * 2, height: scale * 3)
    }
}
