import SwiftUI
import UIKit

struct ShipmentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ShipmentStore

    let shipmentID: UUID

    @State private var reminderEnabled = false
    @State private var reminderDate = Date().addingTimeInterval(8 * 60 * 60)
    @State private var showingDeleteConfirmation = false
    @State private var reminderBusy = false
    @State private var reminderInitialized = false
    @State private var reminderError: String?
    @State private var queryPhone = ""
    @State private var hasSavedPhone = false
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
                                get: { CarrierDetector.allCarriers.first(where: { $0.code == shipment.carrierCode }) ?? .init(id: shipment.carrierCode, name: shipment.carrierName, code: shipment.carrierCode) },
                                set: { carrier in
                                    saveEdit { try store.updateCarrierThrowing(id: shipmentID, carrier: carrier) }
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

                    Section("物流刷新与来源") {
                        LabeledContent("添加来源", value: ShipmentRefreshPresentation.origin(shipment))
                        LabeledContent("当前物流来源", value: ShipmentRefreshPresentation.source(shipment))
                        Picker("默认查询渠道", selection: Binding(
                            get: { shipment.refreshChannel == "uapi" ? "uapi" : "automatic" },
                            set: { channel in
                                guard !querying, !store.isHistoricalSnapshot else { return }
                                do {
                                    try TrackingRefreshService.live().setRefreshChannel(id: shipmentID, channel: channel == "uapi" ? "uapi" : nil)
                                    try store.reload()
                                } catch { queryMessage = error.localizedDescription; try? store.reload() }
                            }
                        )) {
                            Text("跟随添加来源").tag("automatic")
                            Text("UAPI（可能消耗积分）").tag("uapi")
                        }
                        .disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        Text("跟随来源：淘宝／京东／拼多多关联票使用对应平台，原UAPI／未关联票沿用UAPI。商城失败不会自动转收费查询；修改渠道不会改变添加来源。当前物流来源仅表示上次成功查询渠道，不因导入或切换默认渠道而改变。")
                            .font(.footnote)
                        Button(querying ? "正在查询" : "刷新物流（按默认渠道）") {
                            refreshLogistics(mode: .automatic)
                        }
                        .disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        LabeledContent("上次成功查询", value: shipment.lastQueriedAt.map { ShipmentDateDisplay.string($0) } ?? "尚无成功查询")
                        if let error = shipment.lastRefreshError, !error.isEmpty {
                            Text("最近刷新失败：\(error)").font(.footnote).foregroundStyle(.red)
                            Text("失败未覆盖已有物流；以下可能是上次成功数据，并非实时结果。")
                                .font(.footnote)
                        }
                        if shipment.logisticsInfo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            Text("暂无物流轨迹；显示的状态不代表实时物流。")
                                .font(.footnote)
                        }
                        if let queryMessage { Text(queryMessage).font(.footnote) }
                    }

                    Section("UAPI备用查询（可能消耗积分）") {
                        LabeledContent("本票手机尾号", value: hasSavedPhone ? "已保存" : "未保存")
                        TextField("手机尾号（留空复用已保存值）", text: $queryPhone)
                            .keyboardType(.numberPad)
                            .disabled(querying || store.isHistoricalSnapshot)
                        Text("以下尾号仅供UAPI使用，商城查询不使用此尾号。填写后在UAPI查询时为本票保存，后续UAPI刷新及快捷指令复用。仅存本机钥匙串，不进入JSON备份。网络查询失败也会保留填写值。")
                            .font(.footnote)
                        Button("保存／修改尾号（不查询）") {
                            do {
                                try TrackingRefreshService.live().setPhone(id: shipmentID, phone: queryPhone)
                                queryPhone = ""
                                hasSavedPhone = true
                                queryMessage = "本票手机尾号已保存。"
                            } catch { queryMessage = error.localizedDescription }
                        }.disabled(querying || store.isHistoricalSnapshot || queryPhone.isEmpty)
                        Button("清除本票已保存尾号", role: .destructive) {
                            do {
                                try TrackingRefreshService.live().setPhone(id: shipmentID, phone: nil)
                                queryPhone = ""
                                hasSavedPhone = false
                                queryMessage = "本票保存的手机尾号已清除。"
                            } catch { queryMessage = error.localizedDescription }
                        }.disabled(querying || store.isHistoricalSnapshot)
                        Button(querying ? "正在查询" : "仅本次使用UAPI备用刷新（可能消耗积分）") {
                            refreshLogistics(mode: .uapi)
                        }.disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        Text("这是单次明确选择，不修改默认渠道或添加来源。")
                            .font(.footnote)
                    }

                    Section("状态") {
                        Picker("物流状态", selection: Binding(
                            get: { shipment.status },
                            set: { value in saveEdit { try store.updateStatusThrowing(id: shipmentID, status: value) } }
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
                                LabeledContent("物流发生时间", value: ShipmentDateDisplay.string(time))
                            }
                        }
                    }

                    if let query = shipment.queryInfo, !query.isEmpty {
                        Section("本次查询完整信息") {
                            Text(query).textSelection(.enabled)
                        }
                    }

                    Section("备注与取件码") {
                        TextField("备注", text: Binding(
                            get: { shipment.note },
                            set: { value in saveEdit { try store.updateNoteThrowing(id: shipmentID, note: value) } }
                        ))
                        TextField("取件码", text: Binding(
                            get: { shipment.pickupCode },
                            set: { value in saveEdit { try store.updatePickupCodeThrowing(id: shipmentID, pickupCode: value) } }
                        ))
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

                    .disabled(reminderBusy || store.isHistoricalSnapshot)

                    Section("记录") {
                        LabeledContent("添加时间", value: ShipmentDateDisplay.string(shipment.createdAt))
                        if let lastCheckedAt = shipment.lastCheckedAt {
                            LabeledContent("最后查看", value: ShipmentDateDisplay.string(lastCheckedAt))
                        }
                        Button {
                            saveEdit { try store.markCheckedThrowing(id: shipmentID) }
                        } label: {
                            Label("标记为刚刚查看", systemImage: "arrow.clockwise")
                        }
                    }

                    Section {
                        Button("删除这条快递", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                        .disabled(reminderBusy || store.isHistoricalSnapshot)
                    }
                }
                .navigationTitle(shipment.carrierName)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    reminderEnabled = shipment.reminderDate != nil
                    reminderDate = shipment.reminderDate ?? Date().addingTimeInterval(8 * 60 * 60)
                    reminderInitialized = true
                    do { hasSavedPhone = try TrackingRefreshService.live().savedPhone(id: shipmentID) != nil }
                    catch { queryMessage = "无法读取已保存尾号：\(error.localizedDescription)" }
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

    private func refreshLogistics(mode: TrackingRefreshMode) {
        guard !querying, !store.isHistoricalSnapshot, let current = shipment,
              current.status != .archived else { return }
        let legacyUAPIOrigin = current.originPlatform == nil || current.originPlatform == "manual" || current.originPlatform == "uapi"
        let usesUAPI = mode == .uapi || (mode == .automatic &&
            (current.refreshChannel == "uapi" || (legacyUAPIOrigin && current.taobaoOrderID == nil)))
        let suppliedPhone = usesUAPI && !queryPhone.isEmpty ? queryPhone : nil
        querying = true
        Task { @MainActor in
            defer {
                querying = false
                if let saved = try? TrackingRefreshService.live().savedPhone(id: shipmentID) {
                    hasSavedPhone = !saved.isEmpty
                }
            }
            do {
                let service = try TrackingRefreshService.live()
                let completed = try await service.refresh(id: shipmentID, phone: suppliedPhone,
                    expectedTrackingNumber: CarrierDetector.sanitize(current.trackingNumber), mode: mode)
                let latest = try ShipmentRefreshPresentation.snapshot(service, id: shipmentID,
                    number: CarrierDetector.sanitize(current.trackingNumber))
                try store.reload()
                if usesUAPI { queryPhone = "" }
                queryMessage = ShipmentRefreshPresentation.result(latest, newlyDelivered: completed)
            } catch {
                queryMessage = error.localizedDescription
                try? store.reload()
            }
        }
    }

    private func saveEdit(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            // Inputs read only committed values; force a refresh after a rejected edit.
            try? store.reload()
            reminderError = "修改未保存，已恢复实际记录：\(error.localizedDescription)"
        }
    }

    private func handleReminderToggle(_ enabled: Bool, shipment: Shipment) {
        guard requireReminderWriteAccess() else { return }
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

    private func requireReminderWriteAccess() -> Bool {
        do {
            try ReminderWriteAccess.requireWritable(isHistoricalSnapshot: store.isHistoricalSnapshot)
            return true
        } catch {
            restoreReminderControls()
            reminderError = "历史快照只读，未操作系统提醒。"
            return false
        }
    }

    private func scheduleReminder(shipment: Shipment, date: Date) {
        guard requireReminderWriteAccess(), !reminderBusy else { return }
        guard store.beginReminderOperation() else { restoreReminderControls(); reminderError = "提醒操作正在进行，请稍后重试。"; return }
        reminderBusy = true
        Task { @MainActor in
            defer { reminderBusy = false; store.endReminderOperation() }
            guard requireReminderWriteAccess() else { return }
            guard await NotificationManager.shared.requestAuthorization() else {
                restoreReminderControls()
                reminderError = "没有通知权限，提醒未更改。请在系统设置中开启通知。"
                return
            }
            guard requireReminderWriteAccess(), let current = store.shipment(id: shipmentID) else { return }
            do {
                try await NotificationManager.shared.scheduleReminder(for: current, at: date)
                do {
                    try store.updateReminderThrowing(id: shipmentID, date: date)
                } catch {
                    let saveError = error.localizedDescription
                    // Restore the old request when persistence fails.
                    do {
                        try await ReminderCompensation.restore(oldDate: current.reminderDate,
                            schedule: { try await NotificationManager.shared.scheduleReminder(for: current, at: $0) },
                            cancel: { NotificationManager.shared.cancelReminder(for: shipmentID) })
                    } catch {
                        reminderError = "提醒保存失败（\(saveError)），且旧提醒恢复失败（\(error.localizedDescription)）；已请求取消本次新提醒，旧提醒未恢复。请重新设置提醒。"
                        restoreReminderControls()
                        return
                    }
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
