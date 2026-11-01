import SwiftUI

/// Opening/cancelling only touches local selection; canonical field changes on confirmation.
struct TrainDateField: View {
    let title: String
    @Binding var value: String
    let isDate: Bool
    @State private var showing = false
    @State private var selection = Date()

    init(_ title: String, value: Binding<String>, isDate: Bool) {
        self.title = title
        self._value = value
        self.isDate = isDate
    }
    var body: some View {
        LabeledContent(title) {
            Button {
                selection = TrainDateInput.parsed(value, isDate: isDate) ?? Date()
                showing = true
            } label: {
                Text(value.isEmpty ? "请选择" : (isDate ? TrainDateInput.displayDay(value) : value))
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityLabel(title)
            .accessibilityValue(value.isEmpty ? "未选择" : value)
        }
        .sheet(isPresented: $showing) {
            NavigationStack {
                Form {
                    DatePicker(title, selection: $selection,
                               displayedComponents: isDate ? [.date] : [.hourAndMinute])
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                    Text("请选择并确认；取消不修改原值。日期含年份，时间按北京时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !value.isEmpty {
                        Button("清除此字段", role: .destructive) { value = ""; showing = false }
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认") {
                            value = TrainDateInput.value(selection, isDate: isDate)
                            showing = false
                        }
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .presentationDetents([.medium, .large])
        }
    }
}
