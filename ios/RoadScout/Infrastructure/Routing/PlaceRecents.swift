import Foundation
import Observation

@MainActor final class PlaceRecents: ObservableObject {
    @Published private(set) var recents: [Destination] = []
    private let defaults: UserDefaults
    private let key: String

    var items: [Destination] { recents }

    init(userDefaults: UserDefaults = .standard, key: String = "placeRecents") {
        self.defaults = userDefaults
        self.key = key
        load()
    }

    func add(_ destination: Destination) {
        var list = recents.filter { !sameCoordinate($0, destination) }
        list.insert(destination, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recents = list
        save()
    }

    func remove(_ destination: Destination) {
        recents = recents.filter { $0.id != destination.id && !sameCoordinate($0, destination) }
        save()
    }

    func remove(at offsets: IndexSet) {
        var list = recents
        for index in offsets.sorted().reversed() { if index < list.count { list.remove(at: index) } }
        recents = list
        save()
    }

    func removeAll() { clear() }

    func clear() {
        recents = []
        defaults.removeObject(forKey: key)
    }

    private func sameCoordinate(_ lhs: Destination, _ rhs: Destination) -> Bool {
        lhs.point.latitude == rhs.point.latitude && lhs.point.longitude == rhs.point.longitude
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { recents = []; return }
        recents = (try? JSONDecoder().decode([Destination].self, from: data)) ?? []
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recents) {
            defaults.set(data, forKey: key)
        }
    }
}
