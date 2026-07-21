import SwiftUI

struct BatchImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    @State private var drafts: [ShipmentImportDraft]
    @State private var resultMessage: String?

    init(drafts: [ShipmentImportDraft]) {
        _drafts = State(initialValue: drafts)
    }

    private var selectedCount: Int {
        drafts.filter(\.isSelected).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(
                        "一次识别出 \(drafts.count) 个可能的运单。取消勾选不需要导入的号码。",
                        systemImage: "wand.and.stars"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach($drafts) { $draft in
                    Section {
                        Toggle(isOn: $draft.isSelected) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.trackingNumber)
                                    .font(.headline.monospaced())
                                Text(draft.carrier.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if draft.isSelected {
                            Picker("快递公司", selection: $draft.carrier) {
                                ForEach(CarrierDetector.allCarriers) { carrier in
                                    Text(carrier.name).tag(carrier)
                                }
                            }

                            Picker("状态", selection: $draft.status) {
                                ForEach(ShipmentStatus.allCases.filter { $0 != .archived }) { status in
                                    Text(status.rawValue).tag(status)
                                }
                            }

                            TextField("备注", text: $draft.note)
                            TextField("取件码", text: $draft.pickupCode)
                                .keyboardType(.numbersAndPunctuation)
                        }
                    }
                }
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入 \(selectedCount) 条") {
                        importSelected()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedCount == 0)
                }
            }
            .alert("批量导入", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )) {
                Button("完成") { dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private func importSelected() {
        var added = 0
        var duplicates = 0

        for draft in drafts where draft.isSelected {
            let shipment = Shipment(
                trackingNumber: CarrierDetector.sanitize(draft.trackingNumber),
                carrierName: draft.carrier.name,
                carrierCode: draft.carrier.code,
                status: draft.status,
                note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                pickupCode: draft.pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            if store.add(shipment) {
                added += 1
            } else {
                duplicates += 1
            }
        }

        if duplicates > 0 {
            resultMessage = "成功导入 \(added) 条，跳过 \(duplicates) 条重复运单。"
        } else {
            resultMessage = "成功导入 \(added) 条快递。"
        }
    }
}
