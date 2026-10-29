import SwiftUI

struct PickupView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var showingAdd = false
    @State private var showingGroups = false
    @State private var editing: PickupRecord?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.groups) { group in
                    Section(group.name) {
                        let records = store.pickupRecords.filter { $0.groupID == group.id }
                            .sorted { $0.createdAt > $1.createdAt }
                        if records.isEmpty { Text("暂无取码记录").foregroundStyle(.secondary) }
                        ForEach(records) { record in
                            HStack {
                                Button {
                                    run { try store.setPickupCompleted(id: record.id, completed: !record.isCompleted) }
                                } label: {
                                    Image(systemName: record.isCompleted ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(record.code)，\(record.isCompleted ? "恢复未完成" : "标记完成")")
                                VStack(alignment: .leading) {
                                    Text(record.code).strikethrough(record.isCompleted)
                                    if !record.location.isEmpty { Text(record.location).font(.caption) }
                                    if !record.source.isEmpty { Text(record.source).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button("编辑") { editing = record }
                                    .buttonStyle(.borderless)
                                Menu("移动") {
                                    ForEach(store.groups.filter { $0.id != group.id }) { destination in
                                        Button(destination.name) { run { try store.movePickupRecord(id: record.id, to: destination.id) } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("取码")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("管理分组") { showingGroups = true } }
                ToolbarItem(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { showingAdd = true } }
            }
            .sheet(isPresented: $showingAdd) { AddPickupView() }
            .sheet(isPresented: $showingGroups) { PickupGroupsView() }
            .sheet(item: $editing) { record in EditPickupView(record: record) }
            .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

private struct EditPickupView: View {
    @EnvironmentObject private var store: ShipmentStore
    @Environment(\.dismiss) private var dismiss
    let record: PickupRecord
    @State private var code: String
    @State private var location: String
    @State private var source: String
    @State private var error: String?

    init(record: PickupRecord) {
        self.record = record
        _code = State(initialValue: record.code)
        _location = State(initialValue: record.location)
        _source = State(initialValue: record.source)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("取码（必填）", text: $code).autocorrectionDisabled()
                TextField("地点（可选）", text: $location)
                TextField("来源或备注（可选）", text: $source)
                if record.shipmentID != nil {
                    Text("取码和来源或备注会同步到关联快递。") .font(.footnote)
                }
            }
            .navigationTitle("编辑取码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try store.updatePickupRecord(id: record.id, code: code, location: location, source: source)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct AddPickupView: View {
    @EnvironmentObject private var store: ShipmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var groupID: UUID?
    @State private var code = ""
    @State private var location = ""
    @State private var source = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("取码（必填）", text: $code).autocorrectionDisabled()
                TextField("地点（可选）", text: $location)
                TextField("来源或备注（可选）", text: $source)
                Picker("分组", selection: $groupID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(store.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("相同取码可作为不同记录保存。") .font(.footnote)
            }
            .navigationTitle("添加取码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let groupID else { return }
                        do { try store.addPickupRecord(groupID: groupID, code: code, location: location, source: source); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(groupID == nil || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}

private struct PickupGroupsView: View {
    @EnvironmentObject private var store: ShipmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renameName = ""
    @State private var renaming: PickupGroup?
    @State private var deleting: PickupGroup?
    @State private var destination: UUID?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section("新建分组") {
                    TextField("分组名称", text: $name)
                    Button("创建") { run { try store.createGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines)); name = "" } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("分组（使用编辑按钮排序）") {
                    ForEach(store.groups) { group in
                        HStack {
                            Text(group.name)
                            Spacer()
                            Button("改名") { renameName = group.name; renaming = group }
                            Button("删除", role: .destructive) { destination = nil; deleting = group }
                        }
                    }.onMove { offsets, target in
                        var ids = store.groups.map(\.id); ids.move(fromOffsets: offsets, toOffset: target)
                        run { try store.reorderGroups(ids: ids) }
                    }
                }
            }
            .navigationTitle("管理分组")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }; ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            .alert("分组改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $renameName)
                Button("保存") {
                    if let group = renaming, !renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        run { try store.renameGroup(id: group.id, name: renameName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    renaming = nil
                }
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { renaming = nil }
            }
            .sheet(item: $deleting) { group in
                NavigationStack {
                    Form {
                        let count = store.pickupRecords.filter { $0.groupID == group.id }.count
                        Text("删除“\(group.name)”后，引用此分组的快捷指令和小组件需重新选择。")
                        if count > 0 {
                            Text("此分组有 \(count) 条记录，须先选择迁移目标。")
                        }
                        Text("若此分组是快递默认分组，即使没有记录也须选择迁移目标。")
                        Picker("迁移至", selection: $destination) {
                            Text("请选择").tag(Optional<UUID>.none)
                            ForEach(store.groups.filter { $0.id != group.id }) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("确认删除", role: .destructive) {
                            do { try store.deleteGroup(id: group.id, moveTo: destination); deleting = nil }
                            catch { self.error = error.localizedDescription }
                        }.disabled(count > 0 && destination == nil)
                    }
                    .navigationTitle("删除分组")
                    .toolbar { Button("取消") { deleting = nil } }
                    .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                        Button("知道了", role: .cancel) { error = nil }
                    } message: { Text(error ?? "") }
                }
            }
            .alert("操作失败", isPresented: Binding(get: { error != nil && deleting == nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}
