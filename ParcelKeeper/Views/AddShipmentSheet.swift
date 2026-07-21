import SwiftUI

struct AddShipmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    let initialDraft: ShipmentImportDraft

    @State private var trackingNumber: String
    @State private var selectedCarrier: CarrierOption
    @State private var status: ShipmentStatus
    @State private var note: String
    @State private var pickupCode: String
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(8 * 60 * 60)
    @State private var showingDuplicateAlert = false
    @State private var notificationDenied = false
    @State private var isSaving = false

    init(draft: ShipmentImportDraft) {
        initialDraft = draft
        _trackingNumber = State(initialValue: draft.trackingNumber)
        _selectedCarrier = State(initialValue: draft.carrier)
        _status = State(initialValue: draft.status)
        _note = State(initialValue: draft.note)
        _pickupCode = State(initialValue: draft.pickupCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("运单信息") {
                    TextField("运单号", text: $trackingNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                        .onChange(of: trackingNumber) { _, newValue in
                            intelligentlyUpdateCarrier(for: newValue)
                        }

                    Picker("快递公司", selection: $selectedCarrier) {
                        ForEach(CarrierDetector.allCarriers) { carrier in
                            Text(carrier.name).tag(carrier)
                        }
                    }

                    if selectedCarrier == CarrierDetector.unknown || initialDraft.confidence < 0.8 {
                        Label("识别结果可能不准确，保存前确认一下快递公司。", systemImage: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("当前状态", selection: $status) {
                        ForEach(ShipmentStatus.allCases.filter { $0 != .archived }) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                }

                Section("智能识别结果") {
                    TextField("备注，例如：拼多多 · 手机壳", text: $note)
                    TextField("取件码", text: $pickupCode)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section("提醒") {
                    Toggle("设置查看/取件提醒", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker(
                            "提醒时间",
                            selection: $reminderDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }
            }
            .navigationTitle("添加快递")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveShipment()
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存").fontWeight(.semibold)
                        }
                    }
                    .disabled(CarrierDetector.sanitize(trackingNumber).count < 8 || isSaving)
                }
            }
            .alert("这个运单已经保存过了", isPresented: $showingDuplicateAlert) {
                Button("知道了", role: .cancel) {}
            }
            .alert("没有通知权限", isPresented: $notificationDenied) {
                Button("继续", role: .cancel) { dismiss() }
            } message: {
                Text("快递已经保存，但提醒未创建。可以稍后在设置中开启通知权限。")
            }
        }
    }

    private func intelligentlyUpdateCarrier(for value: String) {
        let normalized = CarrierDetector.sanitize(value)
        guard normalized.count >= 8 else { return }
        let detection = CarrierDetector.detect(normalized)
        guard detection.carrier != CarrierDetector.unknown, detection.confidence >= 0.75 else { return }
        selectedCarrier = detection.carrier
    }

    private func saveShipment() {
        let normalized = CarrierDetector.sanitize(trackingNumber)
        let shipment = Shipment(
            trackingNumber: normalized,
            carrierName: selectedCarrier.name,
            carrierCode: selectedCarrier.code,
            status: status,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            pickupCode: pickupCode.trimmingCharacters(in: .whitespacesAndNewlines),
            reminderDate: reminderEnabled ? reminderDate : nil
        )

        guard store.add(shipment) else {
            showingDuplicateAlert = true
            return
        }

        guard reminderEnabled else {
            dismiss()
            return
        }

        isSaving = true
        Task { @MainActor in
            let granted = await NotificationManager.shared.requestAuthorization()
            guard granted else {
                isSaving = false
                notificationDenied = true
                return
            }
            try? await NotificationManager.shared.scheduleReminder(for: shipment, at: reminderDate)
            dismiss()
        }
    }
}
