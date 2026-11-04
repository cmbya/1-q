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
    @State private var reminderError: String?
    @State private var queryPhone = ""
    @State private var savedPhone = ""
    @State private var phoneLoaded = false
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

                        HStack {
                            Text(shipment.trackingNumber)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = shipment.trackingNumber
                            } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("复制运单号")
                        }
                    }

                    Section("状态") {
                        if shipment.statusDisplayText != shipment.status.rawValue {
                            Text("本地状态，待刷新核实")
                                .font(.footnote)
                        }
                        Picker("物流状态", selection: Binding(
                            get: { shipment.status },
                            set: { value in saveEdit { try store.updateStatusThrowing(id: shipmentID, status: value) } }
                        )) {
                            ForEach(ShipmentStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                    }

                    Section("物流刷新") {
                        Picker("默认渠道", selection: Binding(
                            get: { shipment.refreshChannel ?? "automatic" },
                            set: { channel in
                                guard !querying, !store.isHistoricalSnapshot else { return }
                                do {
                                    try TrackingRefreshService.live().setRefreshChannel(id: shipmentID, channel: channel == "automatic" ? nil : channel)
                                    try store.reload()
                                } catch { queryMessage = error.localizedDescription; try? store.reload() }
                            }
                        )) {
                            Text("跟随来源 · \(automaticChannelName(shipment))").tag("automatic")
                            Text("UAPI").tag("uapi")
                            Text("Tmini").tag("tmini")
                        }
                        .disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        Button(querying ? "正在查询" : "刷新物流 · \(resolvedChannelName(shipment))") {
                            refreshLogistics(mode: .automatic)
                        }.disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        Button { refreshLogistics(mode: .tmini) } label: {
                            HStack { Text("Tmini 刷新"); Spacer(); Text("4积分/次").foregroundStyle(.secondary) }
                        }.disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        Button { refreshLogistics(mode: .uapi) } label: {
                            HStack { Text("UAPI 刷新"); Spacer(); Text("40积分/次").foregroundStyle(.secondary) }
                        }.disabled(querying || store.isHistoricalSnapshot || shipment.status == .archived)
                        HStack {
                            Text("手机尾号")
                            TextField("选填 · 顺丰查询", text: $queryPhone)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: queryPhone) { _, value in
                                    guard phoneLoaded, value != savedPhone else { return }
                                    guard value.isEmpty || (value.utf8.count == 4 && value.utf8.allSatisfy({ (48...57).contains($0) })) else { return }
                                    savePhone()
                                }
                        }.disabled(querying || store.isHistoricalSnapshot)
                        LabeledContent("添加来源", value: ShipmentRefreshPresentation.origin(shipment))
                            .font(.footnote).foregroundStyle(.secondary)
                        LabeledContent("上次查询", value: "\(ShipmentRefreshPresentation.source(shipment)) · \(shipment.lastQueriedAt.map { ShipmentDateDisplay.string($0) } ?? "未查询")")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = shipment.lastRefreshError, !error.isEmpty {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if let queryMessage { Text(queryMessage).font(.footnote) }
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

                    Section("提醒") {
                        // Only user binding setters write reminders; reloads and
                        // compensation update state without another system write.
                        Toggle("设置提醒", isOn: Binding(
                            get: { reminderEnabled },
                            set: { enabled in
                                reminderEnabled = enabled
                                handleReminderToggle(enabled, shipment: shipment)
                            }
                        ))

                        if reminderEnabled {
                            DatePicker(
                                "提醒时间",
                                selection: Binding(
                                    get: { reminderDate },
                                    set: { date in
                                        reminderDate = date
                                        if reminderEnabled { scheduleReminder(shipment: shipment, date: date) }
                                    }
                                ),
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    }

                    .disabled(reminderBusy || store.reminderOperationInProgress || store.isHistoricalSnapshot)

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

                    Section("备注") {
                        TextField("添加备注", text: Binding(
                            get: { shipment.note },
                            set: { value in saveEdit { try store.updateNoteThrowing(id: shipmentID, note: value) } }
                        ), axis: .vertical)
                        .lineLimit(2...6)
                    }.disabled(store.isHistoricalSnapshot)

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
                    synchronizeReminderControls()
                    do {
                        savedPhone = try TrackingRefreshService.live().savedPhone(id: shipmentID) ?? ""
                        queryPhone = savedPhone
                        phoneLoaded = true
                    }
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
        .onChange(of: shipment?.reminderDate) { _, _ in synchronizeReminderControls() }
        .onChange(of: store.reminderOperationInProgress) { _, _ in synchronizeReminderControls() }
        .alert("操作未完成", isPresented: Binding(
            get: { reminderError != nil },
            set: { if !$0 { reminderError = nil } }
        )) { Button("知道了", role: .cancel) {} } message: { Text(reminderError ?? "") }
    }

    private func resolvedChannelName(_ shipment: Shipment) -> String {
        do {
            switch try TrackingRefreshService.resolvedChannel(shipment) {
            case "kdyzm": return "后台（已停用）"
            case "taobao": return "淘宝"
            case "pdd": return "拼多多"
            case "jd": return "京东（已停用）"
            case "uapi": return "UAPI"
            case "tmini": return "Tmini"
            default: return "不可用"
            }
        } catch let retired as RetiredTrackingChannel {
            return retired == .jd ? "京东（已停用）" : "后台（已停用）"
        } catch { return "不可用" }
    }

    private func automaticChannelName(_ shipment: Shipment) -> String {
        var automatic = shipment
        automatic.refreshChannel = nil
        return resolvedChannelName(automatic)
    }

    @discardableResult private func savePhone() -> Bool {
        guard phoneLoaded, !querying, !store.isHistoricalSnapshot else { return false }
        if queryPhone == savedPhone { return true }
        do {
            try TrackingRefreshService.live().setPhone(id: shipmentID, phone: queryPhone.isEmpty ? nil : queryPhone)
            savedPhone = queryPhone
            return true
        } catch { queryMessage = error.localizedDescription; return false }
    }

    private func refreshLogistics(mode: TrackingRefreshMode) {
        guard !querying, !store.isHistoricalSnapshot, let current = shipment,
              current.status != .archived else { return }
        let usesUAPI = (try? TrackingRefreshService.resolvedChannel(current, mode: mode)) == "uapi"
        guard savePhone() else { return }
        let suppliedPhone = usesUAPI && !savedPhone.isEmpty ? savedPhone : nil
        querying = true
        Task { @MainActor in
            defer {
                querying = false
                if let saved = try? TrackingRefreshService.live().savedPhone(id: shipmentID) {
                    savedPhone = saved
                }
            }
            do {
                let service = try TrackingRefreshService.live()
                var isCached = false
                let completed = try await service.refresh(id: shipmentID, phone: suppliedPhone,
                    expectedTrackingNumber: CarrierDetector.sanitize(current.trackingNumber), mode: mode, cacheFeedback: { isCached = $0 })
                _ = try ShipmentRefreshPresentation.snapshot(service, id: shipmentID,
                    number: CarrierDetector.sanitize(current.trackingNumber))
                try store.reload()

                queryMessage = isCached ? "已读取缓存" : (completed ? "物流已更新，已签收" : "物流已更新")
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
            defer { store.endReminderOperation(); synchronizeReminderControls() }
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
        // Failed writes share the same idle-only projection as external reloads.
        // A running local operation restores from its defer after unlocking.
        synchronizeReminderControls()
    }

    private func synchronizeReminderControls() {
        // Reload can arrive while scheduling/compensation/reconciliation awaits.
        // Defer to unlock, then reflect committed state (also in read-only history).
        guard !(reminderBusy || store.reminderOperationInProgress) else { return }
        let saved = shipment?.reminderDate
        reminderEnabled = saved != nil
        reminderDate = saved ?? Date().addingTimeInterval(8 * 60 * 60)
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
            defer { reminderBusy = false; store.endReminderOperation(); synchronizeReminderControls() }
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

