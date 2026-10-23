import CoreLocation
import Foundation
import MapKit

struct SearchResult: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let name: String
    let address: String?
    let locality: String?
    let category: String?
    let symbol: String?
    let distance: Double?
    let phoneNumber: String?
    let website: URL?
    let coordinate: CLLocationCoordinate2D

    var point: GeoPoint {
        GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    init(id: UUID = UUID(), name: String, address: String? = nil, locality: String? = nil,
         category: String? = nil, symbol: String? = nil, distance: Double? = nil,
         coordinate: CLLocationCoordinate2D, phoneNumber: String? = nil, website: URL? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.locality = locality
        self.category = category
        self.symbol = symbol
        self.distance = distance
        self.coordinate = coordinate
        self.phoneNumber = phoneNumber
        self.website = website
    }

    init(id: UUID = UUID(), name: String, address: String? = nil, locality: String? = nil,
         category: String? = nil, symbol: String? = nil, distance: Double? = nil,
         coordinate: GeoPoint, phoneNumber: String? = nil, website: URL? = nil) {
        self.init(id: id, name: name, address: address, locality: locality, category: category,
                   symbol: symbol, distance: distance, coordinate: coordinate.coordinate,
                   phoneNumber: phoneNumber, website: website)
    }

    init(name: String, point: GeoPoint) {
        self.init(name: name, coordinate: point.coordinate)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, address, locality, category, symbol, distance, latitude, longitude, phoneNumber, website
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        locality = try c.decodeIfPresent(String.self, forKey: .locality)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        distance = try c.decodeIfPresent(Double.self, forKey: .distance)
        phoneNumber = try c.decodeIfPresent(String.self, forKey: .phoneNumber)
        website = try c.decodeIfPresent(URL.self, forKey: .website)
        let latitude = try c.decode(Double.self, forKey: .latitude)
        let longitude = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(locality, forKey: .locality)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(symbol, forKey: .symbol)
        try c.encodeIfPresent(distance, forKey: .distance)
        try c.encodeIfPresent(phoneNumber, forKey: .phoneNumber)
        try c.encodeIfPresent(website, forKey: .website)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.address == rhs.address
            && lhs.locality == rhs.locality && lhs.category == rhs.category
            && lhs.symbol == rhs.symbol && lhs.distance == rhs.distance
            && lhs.phoneNumber == rhs.phoneNumber && lhs.website == rhs.website
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(address)
        hasher.combine(locality)
        hasher.combine(category)
        hasher.combine(symbol)
        hasher.combine(distance)
        hasher.combine(phoneNumber)
        hasher.combine(website)
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }

    func withDistance(_ distance: Double?) -> SearchResult {
        SearchResult(id: id, name: name, address: address, locality: locality, category: category,
                     symbol: symbol, distance: distance, coordinate: coordinate,
                     phoneNumber: phoneNumber, website: website)
    }
}
