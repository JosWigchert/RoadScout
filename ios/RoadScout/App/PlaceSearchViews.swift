import MapKit
import SwiftUI

enum PlaceCategoryStyle {
    static func title(for category: String?) -> String {
        switch category {
        case MKPointOfInterestCategory.foodMarket.rawValue: String(localized: "Supermarket")
        case MKPointOfInterestCategory.store.rawValue: String(localized: "Shop")
        case MKPointOfInterestCategory.cafe.rawValue: String(localized: "Café")
        case MKPointOfInterestCategory.restaurant.rawValue: String(localized: "Restaurant")
        case MKPointOfInterestCategory.bakery.rawValue: String(localized: "Bakery")
        case MKPointOfInterestCategory.hotel.rawValue: String(localized: "Hotel")
        case MKPointOfInterestCategory.gasStation.rawValue: String(localized: "Petrol station")
        case MKPointOfInterestCategory.evCharger.rawValue: String(localized: "EV charging")
        case MKPointOfInterestCategory.parking.rawValue: String(localized: "Parking")
        case MKPointOfInterestCategory.hospital.rawValue: String(localized: "Hospital")
        case MKPointOfInterestCategory.pharmacy.rawValue: String(localized: "Pharmacy")
        case MKPointOfInterestCategory.park.rawValue: String(localized: "Park")
        case MKPointOfInterestCategory.museum.rawValue: String(localized: "Museum")
        case MKPointOfInterestCategory.airport.rawValue: String(localized: "Airport")
        case MKPointOfInterestCategory.publicTransport.rawValue: String(localized: "Public transport")
        default: String(localized: "Place")
        }
    }

    static func color(for symbol: String?) -> Color {
        switch symbol {
        case "cart.fill", "birthday.cake.fill": .orange
        case "fork.knife", "cup.and.saucer.fill": .orange
        case "leaf.fill", "mountain.2.fill", "tent.fill": .green
        case "cross.fill", "pills.fill": .red
        case "fuelpump.fill", "bolt.car.fill", "tram.fill", "airplane": .indigo
        case "bed.double.fill", "building.columns.fill": .purple
        default: .gray
        }
    }
}

enum PlaceDistanceFormatter {
    static func string(_ meters: Double, unit: SpeedUnit) -> String {
        let short = meters < (unit == .milesPerHour ? 160.9344 : 1_000)
        let output: UnitLength = unit == .milesPerHour ? (short ? .feet : .miles) : (short ? .meters : .kilometers)
        let distance = Measurement(value: meters, unit: UnitLength.meters).converted(to: output)
        return "\(distance.value.formatted(.number.precision(.fractionLength(short ? 0 : 1)))) \(distance.unit.symbol)"
    }
}

struct PlaceCategoryBadge: View {
    let symbol: String?
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol ?? "mappin")
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(PlaceCategoryStyle.color(for: symbol).gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

struct PlaceResultRow: View {
    let destination: Destination
    let distance: String?

    var body: some View {
        HStack(spacing: 14) {
            PlaceCategoryBadge(symbol: destination.symbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(destination.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text([distance, destination.address ?? destination.locality ?? PlaceCategoryStyle.title(for: destination.category)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(minHeight: 82)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PlaceSuggestionRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            PlaceCategoryBadge(symbol: "magnifyingglass")
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle.isEmpty ? String(localized: "Search nearby") : subtitle)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.left")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(minHeight: 76)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DestinationDetailsView: View {
    let destination: Destination
    let distance: String?
    var driveTitle: String = String(localized: "Drive here")
    var isPreparing = false
    var routeSummary: String?
    var message: String?
    var routes: [DrivingRoute] = []
    var selectedRouteID: String?
    var chooseRoute: (DrivingRoute) -> Void = { _ in }
    let drive: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                PlaceCategoryBadge(symbol: destination.symbol, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(PlaceCategoryStyle.title(for: destination.category))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                    .buttonStyle(MapIconButtonStyle())
                    .accessibilityLabel("Close destination details")
                    .accessibilityHint("Returns to your search results")
            }

            Button(action: drive) {
                Label(driveTitle, systemImage: "car.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isPreparing { ProgressView("Calculating route…") }
                    if let routeSummary {
                        Label(routeSummary, systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                            .font(.subheadline.weight(.medium))
                    }
                    if routes.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                                    Button {
                                        chooseRoute(route)
                                    } label: {
                                        Label("Route \(index + 1) · \(Int(route.durationSeconds / 60)) min",
                                              systemImage: route.id == selectedRouteID ? "checkmark.circle.fill" : "circle")
                                            .font(.subheadline.weight(.medium))
                                            .padding(12)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    if destination.address != nil || destination.locality != nil || distance != nil {
                    VStack(alignment: .leading, spacing: 16) {
                        if let address = destination.address ?? destination.locality {
                            detail("Address", value: address, symbol: "mappin.and.ellipse")
                        }
                        if let distance {
                            if destination.address != nil { Divider() }
                            detail("Distance from you", value: distance, symbol: "location")
                            Text("Approximate straight-line distance")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                    }

                    HStack(spacing: 12) {
                        if let phone = phoneURL {
                            Link(destination: phone) { contactLabel("Call", symbol: "phone.fill") }
                        }
                        if let website = destination.website, ["https", "http"].contains(website.scheme?.lowercased() ?? "") {
                            Link(destination: website) { contactLabel("Website", symbol: "safari") }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    Text("Place information from Apple Maps")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func detail(_ title: LocalizedStringKey, value: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).textSelection(.enabled)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func contactLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    private var phoneURL: URL? {
        guard let phone = destination.phoneNumber else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

#Preview("Place · search row") {
    PlaceResultRow(destination: Destination(name: "Neighbourhood Market", address: "Market Street 12, Utrecht",
        category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
        coordinate: GeoPoint(latitude: 52.09, longitude: 5.12)), distance: "1.2 km")
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
}

#Preview("Place · destination card") {
    DestinationDetailsView(destination: Destination(name: "Neighbourhood Market", address: "Market Street 12, Utrecht",
        category: MKPointOfInterestCategory.foodMarket.rawValue, symbol: "cart.fill",
        coordinate: GeoPoint(latitude: 52.09, longitude: 5.12), website: URL(string: "https://example.com")),
        distance: "1.2 km", drive: {}, close: {})
        .padding(20)
}
