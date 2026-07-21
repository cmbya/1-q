import SwiftUI
import UIKit

struct ShipmentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    let shipmentID: UUID

    @State private var selectedCarrier = CarrierDetector.unknown
    @State private var note = ""
    @State private var pickupCode = ""
    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(8 * 60 * 60)
    @State private var showingDeleteConfirmation = false

    private var shipment: Shipment? {
        store.shipment(id: shipmentID)
    }

    var body: some View {
        Group {
            if let shipment {
                Form {
                    Section("运单") {
                        LabeledContent("快递公司") {
                            Picker("快递公司", selection: $selectedCarrier) {
                                ForEach(CarrierDetector.allCarriers) { carrier in
                                    Text(carrier.name).tag(carrier)
                                }
                            }
                            .labelsHidden()
                        }

                        LabeledContent("运单号") {
                            Text(shipment.trackingNumber)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                        }

                        Button {
                            UIPasteboard.general.string = shipment.trackingNumber
                        } label: {
                            Label("复制运单号", systemImage: "doc.on.doc")
                        }
                    }

                    Section("状态") {
                        Picker("物流状态", selection: Binding(
                            get: { shipment.status },
                            set: { store.updateStatus(id: shipmentID, status: $0) }
                        )) {
                            ForEach(ShipmentStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                    }

                    Section("备注与取件码") {
                        TextField("备注", text: $note)
                            .onChange(of: note) { _, newValue in
                                store.updateNote(id: shipmentID, note: newValue)
                            }
                        TextField("取件码", text: $pickupCode)
                            .onChange(of: pickupCode) { _, newValue in
                                store.updatePickupCode(id: shipmentID, pickupCode: newValue)
                            }
                    }

                    Section("提醒") {
                        Toggle("设置提醒", isOn: $reminderEnabled)
                            .onChange(of: reminderEnabled) { _, enabled in
                                handleReminderToggle(enabled, shipment: shipment)
                            }

                        if reminderEnabled {
                            DatePicker(
                                "提醒时间",
                                selection: $reminderDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .onChange(of: reminderDate) { _, newDate in
                                scheduleReminder(shipment: shipment, date: newDate)
                            }
                        }
                    }

                    Section("记录") {
                        LabeledContent("添加时间", value: shipment.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let lastCheckedAt = shipment.lastCheckedAt {
                            LabeledContent("最后查看", value: lastCheckedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button {
                            store.markChecked(id: shipmentID)
                        } label: {
                            Label("标记为刚刚查看", systemImage: "arrow.clockwise")
                        }
                    }

                    Section {
                        Button("删除这条快递", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    }
                }
                .navigationTitle(shipment.carrierName)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    selectedCarrier = CarrierDetector.allCarriers.first(where: { $0.code == shipment.carrierCode }) ?? .init(id: shipment.carrierCode, name: shipment.carrierName, code: shipment.carrierCode)
                    note = shipment.note
                    pickupCode = shipment.pickupCode
                    reminderEnabled = shipment.reminderDate != nil
                    reminderDate = shipment.reminderDate ?? Date().addingTimeInterval(8 * 60 * 60)
                }
                .onChange(of: selectedCarrier) { _, carrier in
                    store.updateCarrier(id: shipmentID, carrier: carrier)
                }
                .confirmationDialog("确定删除这条快递吗？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        NotificationManager.shared.cancelReminder(for: shipmentID)
                        store.delete(id: shipmentID)
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                ContentUnavailableView("快递不存在", systemImage: "shippingbox")
            }
        }
    }

    private func handleReminderToggle(_ enabled: Bool, shipment: Shipment) {
        if enabled {
            scheduleReminder(shipment: shipment, date: reminderDate)
        } else {
            NotificationManager.shared.cancelReminder(for: shipmentID)
            store.updateReminder(id: shipmentID, date: nil)
        }
    }

    private func scheduleReminder(shipment: Shipment, date: Date) {
        Task {
            let granted = await NotificationManager.shared.requestAuthorization()
            guard granted else { return }
            try? await NotificationManager.shared.scheduleReminder(for: shipment, at: date)
            store.updateReminder(id: shipmentID, date: date)
        }
    }
}
