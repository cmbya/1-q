import SwiftUI

/// Read-only navigation input. IDs are canonical UUIDs, never repaired or decoded
/// from another URL shape. No query/fragment/user info is part of this contract.
enum PickupDeepLink {
    static func groupID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "parcelkeeper", components.host == "pickup",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/"), path.count == 37 else { return nil }
        let raw = String(path.dropFirst())
        guard let id = UUID(uuidString: raw),
              id.uuidString.caseInsensitiveCompare(raw) == .orderedSame else { return nil }
        return id
    }

    static func isRoot(_ url: URL) -> Bool {
        url.absoluteString == "parcelkeeper://pickup"
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var selectedTab = 0
    @AppStorage("pickup.contentType") private var contentType = "pickup"
    @State private var selectedTrainTicketID: UUID?
    @State private var selectedPickupGroupID: UUID?
    @State private var pickupNavigationID = UUID()
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tag(0)
                .tabItem {
                    Label("快递", systemImage: "shippingbox.fill")
                }

            VStack(spacing: 0) {
                Picker("信息类型", selection: $contentType) {
                    Text("取件码").tag("pickup")
                    Text("火车票").tag("train")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                if contentType == "train" {
                    TrainTicketListView(selectedTicketID: $selectedTrainTicketID)
                } else {
                    PickupView(selectedGroupID: $selectedPickupGroupID)
                        .id(pickupNavigationID)
                }
            }
                .tag(1)
                .tabItem { Label("取码", systemImage: "number.circle.fill") }

            SettingsView()
                .tag(2)
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .onOpenURL { url in
            if let id = PickupDeepLink.groupID(from: url) {
                store.refreshOnForeground()
                // A widget can outlive its deleted group. Fall back to all groups,
                // never substitute an unrelated group or mutate any records.
                selectedPickupGroupID = store.groups.contains { $0.id == id } ? id : nil
                contentType = "pickup"
                selectedTab = 1
                // Reset stale searches/completed filters, including repeated opens.
                pickupNavigationID = UUID()
                return
            }
            if PickupDeepLink.isRoot(url) {
                store.refreshOnForeground()
                selectedPickupGroupID = nil
                contentType = "pickup"
                selectedTab = 1
                // Reset stale searches/completed filters, including repeated opens.
                pickupNavigationID = UUID()
                return
            }
            if url.scheme == "parcelkeeper", url.host == "shipments", url.path.isEmpty {
                store.refreshOnForeground()
                selectedTab = 0
                return
            }
            guard url.scheme == "parcelkeeper", url.host == "train",
                  url.pathComponents.count == 2,
                  let id = UUID(uuidString: url.lastPathComponent) else { return }
            store.refreshOnForeground()
            contentType = "train"
            selectedTab = 1
            selectedTrainTicketID = id
        }
    }
}
