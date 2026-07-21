import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: ShipmentStore

    @State private var exportURL: URL?
    @State private var showingImporter = false
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

                Section("数据备份") {
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
                    importResultMessage = store.importBackup(from: url) ? "备份导入完成。" : (store.lastErrorMessage ?? "导入失败。")
                case .failure(let error):
                    importResultMessage = "导入失败：\(error.localizedDescription)"
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
