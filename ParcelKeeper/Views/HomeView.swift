import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ShipmentStore

    @State private var searchText = ""
    @State private var selectedFilter: ShipmentFilter = .active
    @State private var importRoute: ImportRoute?
    @State private var pasteErrorMessage: String?
    @State private var isProcessingPaste = false
    @State private var manualInput = ""
    @State private var showingManualInput = false
    @State private var successFeedbackTrigger = 0

    private var filteredShipments: [Shipment] {
        store.shipments.filter { shipment in
            let matchesFilter: Bool
            switch selectedFilter {
            case .active:
                matchesFilter = shipment.status != .delivered && shipment.status != .archived
            case .pickup:
                matchesFilter = shipment.status == .readyForPickup
            case .delivered:
                matchesFilter = shipment.status == .delivered
            case .all:
                matchesFilter = true
            }

            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return shipment.trackingNumber.localizedCaseInsensitiveContains(searchText)
                || shipment.carrierName.localizedCaseInsensitiveContains(searchText)
                || shipment.note.localizedCaseInsensitiveContains(searchText)
                || shipment.pickupCode.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [.indigo.opacity(0.16), .cyan.opacity(0.08), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        header
                        pasteCard
                        summaryGrid
                        filterBar
                        shipmentList
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("快递管家")
            .searchable(text: $searchText, prompt: "搜索运单号、快递或备注")
            .sheet(item: $importRoute) { route in
                switch route {
                case .single(let draft):
                    AddShipmentSheet(draft: draft)
                        .environmentObject(store)
                case .batch(_, let drafts):
                    BatchImportSheet(drafts: drafts)
                        .environmentObject(store)
                }
            }
            .alert("没有识别到运单号", isPresented: Binding(
                get: { pasteErrorMessage != nil },
                set: { if !$0 { pasteErrorMessage = nil } }
            )) {
                Button("手动输入") {
                    manualInput = ""
                    showingManualInput = true
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(pasteErrorMessage ?? "请复制包含运单号的文字后重试。")
            }
            .alert("手动输入运单号", isPresented: $showingManualInput) {
                TextField("运单号", text: $manualInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("识别") {
                    let value = manualInput
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        processText(value)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("粘贴按钮偶尔没有返回内容时，可以直接在这里输入。")
            }
            .alert("出现问题", isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { if !$0 { store.lastErrorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "未知错误")
            }
            .sensoryFeedback(.success, trigger: successFeedbackTrigger)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("把快递都放在这里")
                    .font(.title2.bold())
                Text("整段物流信息也能识别，取件码和状态会一起带入")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Spacer()
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.title2)
                .padding(12)
                .background(.thinMaterial, in: Circle())
        }
    }

    private var pasteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("智能粘贴")
                            .font(.headline)
                        Text("支持单号、短信、淘宝/京东/拼多多物流文字和多个运单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isProcessingPaste {
                        ProgressView()
                            .controlSize(.regular)
                            .frame(width: 44, height: 44)
                    } else {
                        PasteButton(payloadType: String.self) { values in
                            handlePastedValues(values)
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(.primary)
                        .accessibilityLabel("粘贴并识别")
                    }
                }

                Button {
                    manualInput = ""
                    showingManualInput = true
                } label: {
                    Label("粘贴没反应？手动输入", systemImage: "keyboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryGrid: some View {
        HStack(spacing: 10) {
            summaryItem(title: "运输中", count: store.shipments.filter { $0.status == .inTransit || $0.status == .outForDelivery }.count, icon: "truck.box")
            summaryItem(title: "待取件", count: store.shipments.filter { $0.status == .readyForPickup }.count, icon: "shippingbox")
            summaryItem(title: "已签收", count: store.shipments.filter { $0.status == .delivered }.count, icon: "checkmark.seal")
        }
    }

    private func summaryItem(title: String, count: Int, icon: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                Text("\(count)")
                    .font(.title2.bold())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filterBar: some View {
        Picker("筛选", selection: $selectedFilter) {
            ForEach(ShipmentFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var shipmentList: some View {
        if filteredShipments.isEmpty {
            GlassCard {
                ContentUnavailableView(
                    searchText.isEmpty ? "还没有快递" : "没有搜索结果",
                    systemImage: searchText.isEmpty ? "shippingbox" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "复制运单号或整段物流文字，点击上方粘贴按钮。" : "换个关键词试试。")
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(filteredShipments) { shipment in
                    NavigationLink {
                        ShipmentDetailView(shipmentID: shipment.id)
                            .environmentObject(store)
                    } label: {
                        GlassCard {
                            ShipmentRow(shipment: shipment)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            guard store.beginReminderOperation() else { store.lastErrorMessage = "提醒操作正在进行，请稍后重试。"; return }
                            defer { store.endReminderOperation() }
                            do {
                                try store.deleteThrowing(id: shipment.id)
                                NotificationManager.shared.cancelReminder(for: shipment.id)
                            } catch { store.lastErrorMessage = error.localizedDescription }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func handlePastedValues(_ values: [String]) {
        guard !isProcessingPaste else { return }
        isProcessingPaste = true

        Task { @MainActor in
            defer { isProcessingPaste = false }
            await Task.yield()
            guard let text = values.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pasteErrorMessage = "系统没有返回可用的文字。可以再点一次，或者使用手动输入。"
                return
            }
            processText(text)
        }
    }

    private func processText(_ text: String) {
        let drafts = SmartShipmentParser.parse(text)
        guard !drafts.isEmpty else {
            if let single = SmartShipmentParser.parseSingleNumber(text) {
                presentImport([single])
            } else {
                pasteErrorMessage = "没有找到像运单号的内容。请复制运单号，或复制包含“物流单号/运单号”的整段文字。"
            }
            return
        }
        presentImport(drafts)
    }

    private func presentImport(_ drafts: [ShipmentImportDraft]) {
        successFeedbackTrigger += 1
        if drafts.count == 1, let first = drafts.first {
            importRoute = .single(first)
        } else {
            importRoute = .batch(UUID(), drafts)
        }
    }
}

private enum ImportRoute: Identifiable {
    case single(ShipmentImportDraft)
    case batch(UUID, [ShipmentImportDraft])

    var id: UUID {
        switch self {
        case .single(let draft): return draft.id
        case .batch(let id, _): return id
        }
    }
}

private enum ShipmentFilter: String, CaseIterable, Identifiable {
    case active = "进行中"
    case pickup = "待取件"
    case delivered = "已签收"
    case all = "全部"

    var id: String { rawValue }
}
