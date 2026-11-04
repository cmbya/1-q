import SwiftUI

struct StatusBadge: View {
    let status: ShipmentStatus
    var displayText: String? = nil

    var body: some View {
        Label(displayText ?? status.rawValue, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}
