import SwiftUI
import PIiOSCore

/// 思考档位：下拉复选框。勾选结果按契约里的固定顺序输出，
/// 与手输逗号列表相比不会再出现重复项、顺序漂移或 BOM 之类的脏值。
struct PIThinkingLevelsPicker: View {
    let title: String
    @Binding var selection: [String]
    var options: [String] = ProviderVendorSchema.thinkingLevels
    var identifier: String = "thinkingLevels.picker"

    private var orderedSelection: [String] {
        options.filter(selection.contains)
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { level in
                Button {
                    toggle(level)
                } label: {
                    if selection.contains(level) {
                        Label(level, systemImage: "checkmark")
                    } else {
                        Text(level)
                    }
                }
            }
            if !selection.isEmpty {
                Divider()
                Button("清空", role: .destructive) { selection = [] }
            }
        } label: {
            PIFormFieldLabel(title)
            HStack(spacing: PISpacing.s8) {
                Text(orderedSelection.isEmpty ? "未选择" : orderedSelection.joined(separator: ", "))
                    .font(PIFont.body)
                    .foregroundStyle(orderedSelection.isEmpty ? PIColor.text3 : PIColor.text)
                    .lineLimit(2)
                Spacer(minLength: PISpacing.s4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .padding(.horizontal, PISpacing.s12)
            .frame(minHeight: PIMetrics.minHitTarget)
            .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(PIColor.separatorStrong, lineWidth: PIMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title)：\(orderedSelection.isEmpty ? "未选择" : orderedSelection.joined(separator: ", "))")
    }

    private func toggle(_ level: String) {
        if let index = selection.firstIndex(of: level) {
            selection.remove(at: index)
        } else {
            selection.append(level)
            selection = options.filter(selection.contains)
        }
    }
}

/// 默认思考档位：下拉单选框，选项只来自已勾选的档位。
struct PIThinkingLevelPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    var identifier: String = "defaultThinkingLevel.picker"

    private var orderedOptions: [String] {
        options.filter { !$0.isEmpty }
    }

    var body: some View {
        Menu {
            Button {
                selection = ""
            } label: {
                if selection.isEmpty {
                    Label("不指定", systemImage: "checkmark")
                } else {
                    Text("不指定")
                }
            }
            ForEach(orderedOptions, id: \.self) { level in
                Button {
                    selection = level
                } label: {
                    if selection == level {
                        Label(level, systemImage: "checkmark")
                    } else {
                        Text(level)
                    }
                }
            }
        } label: {
            PIFormFieldLabel(title)
            HStack(spacing: PISpacing.s8) {
                Text(selection.isEmpty ? "不指定" : selection)
                    .font(PIFont.body)
                    .foregroundStyle(selection.isEmpty ? PIColor.text3 : PIColor.text)
                Spacer(minLength: PISpacing.s4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .padding(.horizontal, PISpacing.s12)
            .frame(minHeight: PIMetrics.minHitTarget)
            .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                    .strokeBorder(PIColor.separatorStrong, lineWidth: PIMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(orderedOptions.isEmpty)
        .opacity(orderedOptions.isEmpty ? 0.55 : 1)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title)：\(selection.isEmpty ? "不指定" : selection)")
    }
}

/// 表单字段的标题行。`PIFormField` 的标题是 private 布局，
/// 这里复用同一套字号/颜色的轻量版本。
private struct PIFormFieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(PIFont.meta)
            .foregroundStyle(PIColor.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
