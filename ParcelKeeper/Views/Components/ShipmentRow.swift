import SwiftUI

struct ShipmentRow: View {
    let shipment: Shipment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(shipment.carrierName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: shipment.status)
            }

            Text(shipment.trackingNumber)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .textSelection(.enabled)

            if let info = shipment.logisticsInfo, !info.isEmpty {
                Text(info).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if let time = shipment.logisticsTime {
                    Text(time.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !shipment.note.isEmpty || !shipment.pickupCode.isEmpty {
                HStack(spacing: 12) {
                    if !shipment.note.isEmpty {
                        Label(shipment.note, systemImage: "tag")
                            .lineLimit(1)
                    }
                    if !shipment.pickupCode.isEmpty {
                        Label(shipment.pickupCode, systemImage: "number")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
