import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var selectedTab = 0
    @AppStorage("pickup.contentType") private var contentType = "pickup"
    @State private var selectedTrainTicketID: UUID?
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
                    PickupView()
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
