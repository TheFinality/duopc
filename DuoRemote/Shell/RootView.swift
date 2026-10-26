import SwiftUI

/// Hosts list ↔ session screen, cross-faded.
struct RootView: View {
    @State var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let session = coordinator.active {
                SessionScreen(session: session, coordinator: coordinator)
                    .transition(.opacity)
            } else {
                HostsListView(coordinator: coordinator)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.active == nil)
        .sheet(item: $coordinator.credentialPrompt) { host in
            CredentialSheet(host: host, coordinator: coordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            coordinator.scenePhaseChanged(phase)
            if phase == .active { SkyTheme.shared.refresh() }
        }
        .onAppear { SkyTheme.shared.start() }
    }
}
