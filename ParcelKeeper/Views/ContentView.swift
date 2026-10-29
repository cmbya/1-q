import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("快递", systemImage: "shippingbox.fill")
                }

            PickupView()
                .tabItem { Label("取码", systemImage: "number.circle.fill") }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
    }
}
