import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ShipmentStore

    @State private var searchText = ""
    @State private var selectedFilter: ShipmentFilter = .active
    @State private var detectedShipment: CarrierDetection?
    @State private var showingAddSheet = false
    @State private var showingPasteError = false

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
            .sheet(isPresented: $showingAddSheet) {
                if let detectedShipment {
                    AddShipmentSheet(detection: detectedShipment)
                        .environmentObject(store)
                }
            }
            .alert("没有识别到运单号", isPresented: $showingPasteError) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("请先复制一段包含运单号的文字，再点击粘贴按钮。")
            }
            .alert("出现问题", isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { if !$0 { store.lastErrorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "未知错误")
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("把快递都放在这里")
                    .font(.title2.bold())
                Text("复制运单号，点一下就能保存")
                    .foregroundStyle(.secondary)
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
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("粘贴新运单")
                        .font(.headline)
                    Text("支持从短信、淘宝、京东或微信复制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                PasteButton(payloadType: String.self) { values in
                    handlePastedText(values.first)
                }
                .buttonBorderShape(.capsule)
                .tint(.primary)
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
                    description: Text(searchText.isEmpty ? "复制一个运单号，点击上方粘贴按钮。" : "换个关键词试试。")
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
                            store.delete(id: shipment.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func handlePastedText(_ text: String?) {
        guard let text,
              let number = CarrierDetector.extractTrackingNumber(from: text) else {
            showingPasteError = true
            return
        }

        detectedShipment = CarrierDetector.detect(number)
        showingAddSheet = true
    }
}

private enum ShipmentFilter: String, CaseIterable, Identifiable {
    case active = "进行中"
    case pickup = "待取件"
    case delivered = "已签收"
    case all = "全部"

    var id: String { rawValue }
}
