import SwiftUI

struct AddShipmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    let detection: CarrierDetection

    @State private var trackingNumber: String
    @State private var selectedCarrier: CarrierOption
    @State private var status: ShipmentStatus = .inTransit
    @State private var note = ""
    @State private var pickupCode = ""
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(8 * 60 * 60)
    @State private var showingDuplicateAlert = false
    @State private var notificationDenied = false

    init(detection: CarrierDetection) {
        self.detection = detection
        _trackingNumber = State(initialValue: detection.trackingNumber)
        _selectedCarrier = State(initialValue: detection.carrier)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("运单信息") {
                    TextField("运单号", text: $trackingNumber)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)

                    Picker("快递公司", selection: $selectedCarrier) {
                        ForEach(CarrierDetector.allCarriers) { carrier in
                            Text(carrier.name).tag(carrier)
                        }
                    }

                    if detection.confidence < 0.8 {
                        Label("自动识别把握不高，请确认快递公司。", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("当前状态", selection: $status) {
                        ForEach(ShipmentStatus.allCases.filter { $0 != .archived }) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                }

                Section("可选信息") {
                    TextField("备注，例如：键盘、手机壳", text: $note)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveShipment() }
                        .fontWeight(.semibold)
                        .disabled(CarrierDetector.sanitize(trackingNumber).count < 8)
                }
            }
            .alert("这个运单已经保存过了", isPresented: $showingDuplicateAlert) {
                Button("知道了", role: .cancel) {}
            }
            .alert("没有通知权限", isPresented: $notificationDenied) {
                Button("继续保存", role: .cancel) { dismiss() }
            } message: {
                Text("快递已经保存，但提醒未创建。可以稍后在设置中开启通知权限。")
            }
        }
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

        Task {
            let granted = await NotificationManager.shared.requestAuthorization()
            guard granted else {
                notificationDenied = true
                return
            }
            try? await NotificationManager.shared.scheduleReminder(for: shipment, at: reminderDate)
            dismiss()
        }
    }
}
