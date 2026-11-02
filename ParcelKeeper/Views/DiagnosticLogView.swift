import SwiftUI
import UIKit

struct DiagnosticLogView: View {
    private let log = DiagnosticLog.shared
    @State private var snapshot: DiagnosticLogSnapshot?
    @State private var exportURL: URL?
    @State private var copiedChangeCount: Int?
    @State private var showClear = false
    @State private var busy = false
    @State private var actionMessage: String?

    var body: some View {
        List {
            Section {
                Text("仅在本机保存诊断事件、原因分类和有界计数，不记录账号、Cookie、网址、订单号、运单号或响应正文。最多保留 500 条 / 512 KB，自动淘汰旧记录。")
                    .font(.footnote)
                Text("操作编号为临时随机别名，非设备标识；时间戳会显示操作时间。仅手动复制或分享，不自动上传。")
                    .font(.footnote)
                Text("关闭后停止新增，已有日志仍保留，可随时清除。")
                    .font(.footnote)
                Toggle("记录本地诊断日志", isOn: Binding(
                    get: { snapshot?.isEnabled ?? false },
                    set: { enabled in
                        busy = true
                        exportURL = nil
                        log.setEnabled(enabled) { updated in
                            snapshot = updated
                            busy = false
                        }
                    }
                ))
                .disabled(busy || snapshot == nil)
            } header: { Text("隐私与记录") }

            Section("状态") {
                if let snapshot {
                    Text(statusText(snapshot.status))
                    Text("已保存 \(snapshot.entryCount) 条")
                    if let issue = snapshot.issue {
                        Text(issueText(issue)).foregroundStyle(.red)
                    }
                } else { ProgressView("读取中…") }
                if let actionMessage { Text(actionMessage).font(.footnote) }
                Button("刷新") { refresh() }.disabled(busy)
            }

            Section("手动导出") {
                Button("复制日志") {
                    busy = true
                    log.refresh { updated in
                        snapshot = updated
                        busy = false
                        guard readable(updated) else { return }
                        // Local-only clipboard, with short expiry; not Universal Clipboard.
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: updated.text]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        copiedChangeCount = UIPasteboard.general.changeCount
                        actionMessage = "已复制；剪贴板内容将在 5 分钟后过期。"
                    }
                }.disabled(busy || snapshot.map { !readable($0) } != false)
                Button("生成分享文件") {
                    busy = true
                    actionMessage = nil
                    log.export { result in
                        busy = false
                        switch result {
                        case .success(let url):
                            exportURL = url
                            actionMessage = "已生成本地文件，请点击分享；不会自动上传。"
                        case .failure:
                            exportURL = nil
                            actionMessage = "导出失败，未生成可分享文件。请检查本地存储或解锁设备后重试。"
                        }
                        log.refresh { snapshot = $0 }
                    }
                }.disabled(busy || snapshot.map { !readable($0) } != false)
                if let exportURL {
                    ShareLink(item: exportURL) { Label("分享日志文件", systemImage: "square.and.arrow.up") }
                }
                Text("分享或复制后，请先检查内容。清除会删除本应用保存的日志和导出文件，并清空本页面复制且尚未被更改的诊断剪贴板。本应用无法删除已发给其他应用、保存到其他位置或由系统分享界面复制的副本。")
                    .font(.footnote)
            }

            Section("日志内容") {
                if let snapshot {
                    Text(snapshot.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section {
                Button("清除日志及本地导出副本", role: .destructive) { showClear = true }
                    .disabled(busy)
            }
        }
        .navigationTitle("本地诊断日志")
        .task { refresh() }
        .confirmationDialog("删除所有本地诊断日志和本应用保存的导出文件？", isPresented: $showClear, titleVisibility: .visible) {
            Button("删除日志及本地导出副本", role: .destructive) {
                busy = true
                exportURL = nil
                actionMessage = nil
                if copiedChangeCount == UIPasteboard.general.changeCount {
                    UIPasteboard.general.items = []
                }
                copiedChangeCount = nil
                log.clear { updated in
                    snapshot = updated
                    busy = false
                    if updated.issue == nil { actionMessage = "日志和本应用内的导出副本已清除。" }
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func refresh() {
        busy = true
        exportURL = nil
        log.refresh { updated in snapshot = updated; busy = false }
    }
    private func readable(_ value: DiagnosticLogSnapshot) -> Bool {
        value.status == .ready || value.status == .missing
    }
    private func statusText(_ status: DiagnosticLogStatus) -> String {
        switch status {
        case .missing: return "尚无日志文件（不是读取失败）"
        case .ready: return "本地日志可用"
        case .corrupt: return "日志文件损坏或格式不受支持，已停止写入；可清除后重新记录。"
        case .ioFailure: return "本地存储读写失败，未视为空日志；请解锁设备后重试或清除。"
        }
    }
    private func issueText(_ issue: DiagnosticLogIssue) -> String {
        switch issue {
        case .read: return "读取失败，原文件未被覆盖。"
        case .write: return "保存失败，当前显示内容不代表已成功落盘。"
        case .export: return "导出失败，没有可分享的新文件。"
        case .clear: return "清除未全部完成，部分本地文件可能仍存在，请重试。"
        }
    }
}
