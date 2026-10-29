import SwiftUI

struct BatchImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    @State private var drafts: [ShipmentImportDraft]
    @State private var resultMessage: String?
    @State private var hasImportFailures = false

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
                Button(hasImportFailures ? "继续" : "完成") {
                    if !hasImportFailures { dismiss() }
                }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private func importSelected() {
        var added = 0
        var duplicates = 0
        var failures = 0
        var firstError: String?

        for index in drafts.indices where drafts[index].isSelected {
            let draft = drafts[index]
            let shipment = Shipment(
                trackingNumber: CarrierDetector.sanitize(draft.trackingNumber),
                carrierName: draft.carrier.name,
                carrierCode: draft.carrier.code,
                status: draft.status,
                note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                pickupCode: draft.pickupCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            do {
                try store.addThrowing(shipment)
                added += 1
                drafts[index].isSelected = false
            } catch ShipmentStore.ShipmentWriteError.duplicateTrackingNumber {
                duplicates += 1
                drafts[index].isSelected = false
            } catch {
                failures += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        hasImportFailures = failures > 0
        var message = "成功导入 \(added) 条，跳过 \(duplicates) 条重复运单。"
        if failures > 0 {
            message += " \(failures) 条保存失败：\(firstError ?? "未知错误")。失败项仍保持选中，可重试。"
        }
        resultMessage = message
    }
}
