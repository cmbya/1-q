import SwiftUI

@main
struct ParcelKeeperApp: App {
    @StateObject private var store = ShipmentStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .task { _ = await store.reconcileReminders() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    do { try store.reload() }
                    catch { store.lastErrorMessage = error.localizedDescription }
                    Task { @MainActor in _ = await store.reconcileReminders() }
                }
        }
    }
}
