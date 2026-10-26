import SwiftUI

/// Hosts list ↔ session screen, cross-faded.
struct RootView: View {
    @State var coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// Code pages that don't match the app's signature (see `CodeIntegrity`).
    @State private var damagedPages: [Int] = []

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
        .task {
            let damaged = await Task.detached(priority: .utility) { CodeIntegrity.checkInstalledApp() ?? [] }.value
            damagedPages = damaged
        }
        .alert("This copy of DuoPC is damaged", isPresented: Binding(get: { !damagedPages.isEmpty },
                                                                   set: { if !$0 { damagedPages = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Part of the app was damaged while it was being installed (\(damagedPages.count) of its code pages, the first at \(String(format: "0x%x", damagedPages.first ?? 0))), so it will crash when it reaches that part. Delete DuoPC and sideload it again.")
        }
    }
}
