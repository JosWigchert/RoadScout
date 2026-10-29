import SwiftUI

struct DemoTestingView: View {
    let isDemo: Bool
    let startFreeDrive: () -> Void
    let startNavigation: () -> Void
    let exitDemo: () -> Void

    var body: some View {
        Form {
            Section {
                Button("Start free-drive demo", action: startFreeDrive)
                Button("Start navigation demo", action: startNavigation)
            } header: {
                Text("Synthetic GPS")
            } footer: {
                Text("Demos replace the current driving session with simulated GPS. Navigation uses a bundled synthetic route and needs no routing server or location permission. Demo mode resets when the app relaunches.")
            }
            if isDemo {
                Section {
                    Button("Exit Demo", action: exitDemo)
                } footer: {
                    Text("Stops the replay and clears its route. Tap Start driving on the map to use live GPS again.")
                }
            }
        }
        .navigationTitle("Demo & Testing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
