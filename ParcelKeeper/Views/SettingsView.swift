import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: ShipmentStore

    @State private var exportURL: URL?
    @State private var showingImporter = false
    @State private var backupPreview: BackupPreview?
    @State private var showingPreview = false
    @State private var conflictPolicy: BackupConflictPolicy = .keepExisting
    @State private var importResultMessage: String?
    @State private var notificationStatusText = "检查中…"

    var body: some View {
        NavigationStack {
            Form {
                Section("通知") {
                    LabeledContent("权限状态", value: notificationStatusText)
                    Button {
                        Task { await requestNotifications() }
                    } label: {
                        Label("申请通知权限", systemImage: "bell.badge")
                    }
                }

                Section("桌面组件") {
                    NavigationLink("组件 A / B 分组设置") { WidgetSettingsView() }
                }

                Section("AI") {
                    NavigationLink("AI 服务设置") { AISettingsView() }
                }

                Section("数据备份") {
                    if store.isHistoricalSnapshot {
                        Text("当前显示的是只读历史快照，可能已过时，不能代表当前共享数据。")
                            .foregroundStyle(.orange)
                    }
                    Text("备份包含取件码、地址和快递信息，请谨慎分享。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        exportURL = store.makeBackupFile()
                    } label: {
                        Label("生成 JSON 备份", systemImage: "square.and.arrow.up")
                    }

                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享备份文件", systemImage: "paperplane")
                        }
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        Label("导入备份", systemImage: "square.and.arrow.down")
                    }
                }

                Section("关于 1.1") {
                    LabeledContent("版本", value: "1.1.0")
                    Text("当前版本已修复粘贴后偶发空白页的问题，并支持从整段物流文字中识别多个运单、平台来源、取件码和当前状态。实时物流轨迹仍需接入正规的快递查询 API。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .task { await refreshNotificationStatus() }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        backupPreview = try store.previewBackup(from: url)
                        conflictPolicy = .keepExisting
                        showingPreview = true
                    } catch { importResultMessage = "预览失败：\(error.localizedDescription)" }
                case .failure(let error):
                    importResultMessage = "导入失败：\(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingPreview) {
                NavigationStack {
                    Group {
                    if let preview = backupPreview {
                        Form {
                            Section("导入预览") {
                                LabeledContent("分组", value: "\(preview.incoming.groups.count)")
                                LabeledContent("取码记录", value: "\(preview.incoming.records.count)")
                                LabeledContent("快递", value: "\(preview.incoming.shipments.count)")
                                LabeledContent("分组 ID 冲突", value: "\(preview.conflictingGroupIDs.count)")
                                LabeledContent("取码 ID 冲突", value: "\(preview.conflictingRecordIDs.count)")
                                LabeledContent("快递 ID 冲突", value: "\(preview.conflictingShipmentIDs.count)")
                                LabeledContent("运单号冲突", value: "\(preview.conflictingTrackingNumbers.count)")
                                if !preview.conflictingTrackingNumbers.isEmpty {
                                    Text(preview.conflictingTrackingNumbers.joined(separator: "、")).font(.footnote)
                                }
                            }
                            Section("冲突策略") {
                                Picker("ID 或运单号冲突", selection: $conflictPolicy) {
                                    Text("保留现有记录").tag(BackupConflictPolicy.keepExisting)
                                    Text("使用备份中的记录替换").tag(BackupConflictPolicy.replaceExisting)
                                }
                                Text("默认快递分组：保留现有默认；仅当现有默认为空时恢复备份默认。非冲突数据会合并；运单号冲突按整条运单及其关联取码记录保留或替换，替换可能覆盖现有内容。预览后数据若发生变化，需要重新预览。")
                                    .font(.footnote)
                            }
                            Button("确认导入") {
                                guard store.beginReminderOperation() else {
                                    importResultMessage = "提醒操作正在进行，请稍后再导入。"
                                    return
                                }
                                do {
                                    try store.confirmBackupImport(preview, policy: conflictPolicy)
                                    let importedShipments = store.shipments
                                    let refreshWarning = store.lastErrorMessage
                                    Task { @MainActor in
                                        defer { store.endReminderOperation() }
                                        let errors = await NotificationManager.shared.reconcileReminders(with: importedShipments)
                                        let result = errors.isEmpty ? "备份导入完成，未来提醒已对账。" : "备份已导入，但部分提醒未恢复：\n" + errors.joined(separator: "\n")
                                        importResultMessage = [result, refreshWarning].compactMap { $0 }.joined(separator: "\n")
                                    }
                                } catch { store.endReminderOperation(); importResultMessage = "导入失败：\(error.localizedDescription)" }
                                showingPreview = false
                            }
                        }
                    }
                    }
                    .navigationTitle("备份预览")
                    .toolbar { Button("取消") { showingPreview = false } }
                }
            }
            .alert("数据备份", isPresented: Binding(
                get: { importResultMessage != nil },
                set: { if !$0 { importResultMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { importResultMessage = nil }
            } message: {
                Text(importResultMessage ?? "")
            }
        }
    }

    private func requestNotifications() async {
        _ = await NotificationManager.shared.requestAuthorization()
        await refreshNotificationStatus()
    }

    private func refreshNotificationStatus() async {
        let status = await NotificationManager.shared.authorizationStatus()
        switch status {
        case .notDetermined:
            notificationStatusText = "尚未询问"
        case .denied:
            notificationStatusText = "已拒绝"
        case .authorized:
            notificationStatusText = "已允许"
        case .provisional:
            notificationStatusText = "临时允许"
        case .ephemeral:
            notificationStatusText = "临时会话"
        @unknown default:
            notificationStatusText = "未知"
        }
    }
}
