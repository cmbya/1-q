import SwiftUI

@main
struct ParcelKeeperApp: App {
    @StateObject private var store = ShipmentStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
