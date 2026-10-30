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
    @State private var reminderBusy = false
    @State private var reminderInitialized = false
    @State private var reminderError: String?
    @State private var queryPhone = ""
    @State private var querying = false
    @State private var queryMessage: String?

    private var shipment: Shipment? {
        store.shipment(id: shipmentID)
    }

    var body: some View {
        Group {
            if let shipment {
                Form {
                    Section("运单") {
                        LabeledContent("快递公司") {
                            Picker("快递公司", selection: Binding(
                                get: { selectedCarrier },
                                set: { carrier in
                                    selectedCarrier = carrier
                                    store.updateCarrier(id: shipmentID, carrier: carrier)
                                }
                            )) {
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

                    Section("UAPI查询") {
                        TextField("收件人手机尾号（可选，仅本次使用）", text: $queryPhone)
                            .keyboardType(.numberPad)
                        Button(querying ? "正在查询" : "刷新物流") {
                            querying = true
                            Task { @MainActor in
                                defer { querying = false }
                                do {
                                    _ = try await TrackingRefreshService.live().refresh(id: shipmentID, phone: queryPhone.isEmpty ? nil : queryPhone)
                                    try store.reload()
                                    queryPhone = ""
                                    queryMessage = "物流已更新。"
                                } catch { queryMessage = error.localizedDescription; try? store.reload() }
                            }
                        }.disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        if let time = shipment.lastQueriedAt {
                            LabeledContent("最后查询", value: time.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let queryMessage { Text(queryMessage).font(.footnote) }
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

                    if let info = shipment.logisticsInfo, !info.isEmpty {
                        Section("最新物流信息") {
                            Text(info).textSelection(.enabled)
                            if let time = shipment.logisticsTime {
                                LabeledContent("物流发生时间", value: time.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }

                    if let query = shipment.queryInfo, !query.isEmpty {
                        Section("本次查询完整信息") {
                            Text(query).textSelection(.enabled)
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
                                if reminderInitialized { handleReminderToggle(enabled, shipment: shipment) }
                            }

                        if reminderEnabled {
                            DatePicker(
                                "提醒时间",
                                selection: $reminderDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .onChange(of: reminderDate) { _, newDate in
                                if reminderInitialized && reminderEnabled { scheduleReminder(shipment: shipment, date: newDate) }
                            }
                        }
                    }

                    .disabled(reminderBusy)

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
                        .disabled(reminderBusy)
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
                    reminderInitialized = true
                }
                .confirmationDialog("确定删除这条快递吗？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                    Button("删除", role: .destructive) {
                        guard store.beginReminderOperation() else { reminderError = "提醒操作正在进行，请稍后重试。"; return }
                        defer { store.endReminderOperation() }
                        do {
                            try store.deleteThrowing(id: shipmentID)
                            NotificationManager.shared.cancelReminder(for: shipmentID)
                            dismiss()
                        } catch {
                            reminderError = "删除失败：\(error.localizedDescription)"
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                ContentUnavailableView("快递不存在", systemImage: "shippingbox")
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { reminderError != nil },
            set: { if !$0 { reminderError = nil } }
        )) { Button("知道了", role: .cancel) {} } message: { Text(reminderError ?? "") }
    }

    private func handleReminderToggle(_ enabled: Bool, shipment: Shipment) {
        if enabled {
            scheduleReminder(shipment: shipment, date: reminderDate)
        } else {
            guard store.beginReminderOperation() else { restoreReminderControls(); reminderError = "提醒操作正在进行，请稍后重试。"; return }
            defer { store.endReminderOperation() }
            do {
                try store.updateReminderThrowing(id: shipmentID, date: nil)
                NotificationManager.shared.cancelReminder(for: shipmentID)
            } catch {
                restoreReminderControls()
                reminderError = "关闭提醒失败：\(error.localizedDescription)"
            }
        }
    }

    private func restoreReminderControls() {
        reminderInitialized = false
        let saved = store.shipment(id: shipmentID)?.reminderDate
        reminderEnabled = saved != nil
        if let saved { reminderDate = saved }
        // SwiftUI delivers onChange after state updates; suppress restoration callbacks.
        DispatchQueue.main.async { reminderInitialized = true }
    }

    private func scheduleReminder(shipment: Shipment, date: Date) {
        guard !reminderBusy else { return }
        guard store.beginReminderOperation() else { restoreReminderControls(); reminderError = "提醒操作正在进行，请稍后重试。"; return }
        reminderBusy = true
        Task { @MainActor in
            defer { reminderBusy = false; store.endReminderOperation() }
            guard await NotificationManager.shared.requestAuthorization() else {
                restoreReminderControls()
                reminderError = "没有通知权限，提醒未更改。请在系统设置中开启通知。"
                return
            }
            guard let current = store.shipment(id: shipmentID) else { return }
            do {
                try await NotificationManager.shared.scheduleReminder(for: current, at: date)
                do {
                    try store.updateReminderThrowing(id: shipmentID, date: date)
                } catch {
                    let saveError = error.localizedDescription
                    // Restore the old request when persistence fails.
                    if let oldDate = current.reminderDate, oldDate > Date() {
                        do { try await NotificationManager.shared.scheduleReminder(for: current, at: oldDate) }
                        catch { reminderError = "提醒保存失败，且旧提醒恢复失败：\(error.localizedDescription)"; restoreReminderControls(); return }
                    } else { NotificationManager.shared.cancelReminder(for: shipmentID) }
                    restoreReminderControls()
                    reminderError = "提醒保存失败：\(saveError)"
                    return
                }
            } catch {
                restoreReminderControls()
                reminderError = "提醒创建失败：\(error.localizedDescription)"
            }
        }
    }
}
