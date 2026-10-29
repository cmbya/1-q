import SwiftUI

struct PickupView: View {
    @EnvironmentObject private var store: ShipmentStore
    @State private var showingAdd = false
    @State private var showingGroups = false
    @State private var showingImport = false
    @State private var searchText = ""
    @State private var filter = 0
    @State private var deleting: PickupRecord?
    @State private var editing: PickupRecord?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("粘贴文字识别取码", systemImage: "doc.on.clipboard") { showingImport = true }
                }
                Picker("状态", selection: $filter) {
                    Text("未完成").tag(0)
                    Text("已完成").tag(1)
                    Text("全部").tag(2)
                }.pickerStyle(.segmented)
                ForEach(store.groups) { group in
                    Section(group.name) {
                        let records = store.pickupRecords.filter {
                            $0.groupID == group.id && (filter == 2 || $0.isCompleted == (filter == 1)) &&
                            (searchText.isEmpty || [$0.code, $0.location, $0.source].contains { $0.localizedCaseInsensitiveContains(searchText) })
                        }
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
                                if record.shipmentID == nil {
                                    Button("删除", role: .destructive) { deleting = record }.buttonStyle(.borderless)
                                }
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
            .searchable(text: $searchText, prompt: "搜索取件码、地点或备注")
            .confirmationDialog("删除这条取码记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let record = deleting { run { try store.deletePickupRecord(id: record.id) } }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            }
            .navigationTitle("取码")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("管理分组") { showingGroups = true } }
                ToolbarItem(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { showingAdd = true } }
            }
            .sheet(isPresented: $showingAdd) { AddPickupView() }
            .sheet(isPresented: $showingImport) { PickupImportView() }
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
    @State private var duplicate = false
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
                Text("同组未完成的相同取码不重复添加，已完成的历史取码可以再次使用。") .font(.footnote)
            }
            .navigationTitle("添加取码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.pickupRecords.contains(where: { $0.groupID == groupID && !$0.isCompleted && $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code.trimmingCharacters(in: .whitespacesAndNewlines) }) { duplicate = true }
                        else { save() }
                    }.disabled(groupID == nil || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("发现重复取码", isPresented: $duplicate) {
                Button("知道了", role: .cancel) { }
            } message: { Text("此分组已有未完成的相同取码，本次不重复添加。已完成的历史取码可再次使用。") }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        guard let groupID else { return }
        do { try store.addPickupRecord(groupID: groupID, code: code, location: location, source: source); dismiss() }
        catch { self.error = error.localizedDescription }
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


private struct PickupImportView: View {
    @EnvironmentObject private var store: ShipmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PickupTextParser.Candidate] = []
    @State private var code = ""
    @State private var location = ""
    @State private var source = ""
    @State private var groupID: UUID?
    @State private var status = "点击粘贴按钮开始，或直接手动填写。"
    @State private var failures: [AIFailure] = []
    @State private var processing = false
    @State private var task: Task<Void, Never>?
    @State private var duplicate = false
    @State private var error: String?
    @State private var pendingText: String?
    @State private var pendingCandidate: PickupTextParser.Candidate?
    @State private var needsChoice = false
    @State private var requestID = UUID()
    private var hasEdits: Bool { !code.isEmpty || !location.isEmpty || !source.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("主动粘贴") {
                    Text("仅在点击粘贴后读取文字。本地优先识别；无法识别或结果有歧义时，仅在 AI 已开启的情况下将文字发送到配置的服务，该服务可能转发给上游。原文仅在识别或等待替换确认时临时使用，不会保存为记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if processing {
                        ProgressView("正在识别")
                        Button("取消识别") {
                            requestID = UUID(); task?.cancel(); task = nil; processing = false
                            status = "识别已取消，请选择本地候选或手动填写。"
                        }
                    }
                    else {
                        PasteButton(payloadType: String.self) { values in
                            guard let text = values.first, !text.isEmpty else { return }
                            if hasEdits { pendingText = text } else { recognize(text) }
                        }.accessibilityLabel("粘贴并识别取码")
                    }
                    Text(status).font(.footnote)
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        Text("模型 \(failure.model)：\(failure.category.localizedDescription)").font(.footnote)
                    }
                }
                if !candidates.isEmpty {
                    Section("选择候选（选择后可编辑）") {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                            Button(candidate.code) {
                                if hasEdits { pendingCandidate = candidate } else { apply(candidate) }
                            }
                        }
                    }.disabled(processing)
                }
                Section("确认并编辑") {
                    if needsChoice {
                        Text("结果有歧义，请选择候选或明确确认使用手动填写的内容。")
                        Button("确认使用手动填写内容") { needsChoice = false }
                            .disabled(processing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextField("取码（必填）", text: $code).autocorrectionDisabled()
                    TextField("地点（可选）", text: $location)
                    TextField("来源或备注（可选）", text: $source)
                    Picker("分组", selection: $groupID) {
                        Text("请选择").tag(Optional<UUID>.none)
                        ForEach(store.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
            .navigationTitle("识别取码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.pickupRecords.contains(where: { $0.groupID == groupID && !$0.isCompleted && $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code.trimmingCharacters(in: .whitespacesAndNewlines) }) { duplicate = true }
                        else { save() }
                    }.disabled(processing || needsChoice || groupID == nil || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("发现重复取码", isPresented: $duplicate) {
                Button("知道了", role: .cancel) { }
            } message: { Text("此分组已有未完成的相同取码，本次不重复添加。已完成的历史取码可再次使用。") }
            .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .alert("替换已填写内容？", isPresented: Binding(get: { pendingText != nil || pendingCandidate != nil }, set: { if !$0 { pendingText = nil; pendingCandidate = nil } })) {
                Button("替换", role: .destructive) {
                    if let text = pendingText { pendingText = nil; recognize(text) }
                    else if let candidate = pendingCandidate { pendingCandidate = nil; apply(candidate) }
                }
                Button("保留", role: .cancel) { pendingText = nil; pendingCandidate = nil }
            } message: { Text("当前填写的取码、地点和备注将被替换或清空。") }
            .onDisappear { requestID = UUID(); task?.cancel(); task = nil }
        }
    }

    private func recognize(_ text: String) {
        let result = PickupTextParser().parse(text)
        candidates = result.candidates
        failures = []
        code = ""; location = ""; source = ""
        needsChoice = result.isAmbiguous || result.candidates.isEmpty
        if !result.isAmbiguous, result.candidates.count == 1, let candidate = result.candidates.first {
            code = candidate.code; location = candidate.location ?? ""; source = candidate.source ?? ""
        }
        let needsAI = result.isAmbiguous || result.candidates.isEmpty || result.candidates.contains { ($0.location ?? "").isEmpty }
        guard needsAI else { status = "本地识别完成，请核对并编辑后保存。"; return }
        guard AIService().loadConfiguration().enabled else {
            status = "本地结果不确定或未识别；AI 未开启，请选择候选或手动填写。"
            return
        }
        processing = true
        status = "本地结果不确定，正在使用已开启的 AI 识别。"
        let id = UUID()
        requestID = id
        task = Task { @MainActor in
            defer { if requestID == id { processing = false; task = nil } }
            do {
                let extracted = try await AIService().extract(text)
                guard !Task.isCancelled, requestID == id else { return }
                failures = extracted.failures
                let candidate = PickupTextParser.Candidate(code: extracted.code, location: extracted.location, source: extracted.source)
                candidates.append(candidate)
                status = "AI 模型 \(extracted.model) 返回候选，请选择并核对。"
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                let safeError = (error as? AIServiceError) ?? .unavailable
                if case .allModelsFailed(let modelFailures) = safeError { failures = modelFailures }
                status = "AI 识别失败：\(safeError.localizedDescription)。请使用本地候选或手动填写。"
            }
        }
    }

    private func apply(_ candidate: PickupTextParser.Candidate) {
        code = candidate.code; location = candidate.location ?? ""; source = candidate.source ?? ""
        needsChoice = false
    }

    private func save() {
        guard !processing, !needsChoice, let groupID, store.groups.contains(where: { $0.id == groupID }), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try store.addPickupRecord(groupID: groupID, code: code, location: location, source: source); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
