import SwiftUI

struct StatusBadge: View {
    let status: ShipmentStatus

    var body: some View {
        Label(status.rawValue, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}
