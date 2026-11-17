import SwiftUI
import UIKit
import PIiOSCore

/// 设置 → 运行日志（AC-L1/L2/L3/L5/L6/L7）。
///
/// quiet-v2：页面只承担四件事——开关与等级、时间格式、保留记录列表、导出与清空。
/// 每个控件都直接写进 `AppModel` 的配置，不做「编辑后保存」的第二层状态。
struct LogsScreen: View {
    @EnvironmentObject private var model: AppModel

    /// 日志列表：磁盘快照 + 本次运行内存记录合并后的全部可读结果（旧→新）。
    /// 不能只用内存：重启后内存只有新记录、关闭日志后内存为空，都会把磁盘历史从预览里抹掉。
    @State private var records: [PILogRecord] = []
    /// 进页时读到的磁盘历史；每秒刷新时参与合并，清空日志时一并重置。
    @State private var storedSnapshot: [PILogRecord] = []
    @State private var hasLoadedStoredSnapshot = false
    /// 清空会使首屏异步磁盘读取失效，避免迟到的旧快照在清空后回写。
    @State private var previewGeneration = 0
    @State private var isExporting = false
    @State private var exportFile: LogExportFile?
    @State private var showingClearConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                statusSection
                levelSection
                timeFormatSection
                recentSection
                exportSection
                clearSection
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s8)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("运行日志")
        // 进页先取一次完整磁盘快照（重启后内存缓冲为空的情况），之后每秒用
        // 「磁盘快照 + 内存记录」合并出列表；页面消失 `.task` 自动取消，不在主线程读盘。
        .task {
            if !hasLoadedStoredSnapshot {
                hasLoadedStoredSnapshot = true
                let generation = previewGeneration
                let stored = await model.loadStoredLogRecords()
                if generation == previewGeneration {
                    storedSnapshot = stored
                }
            }
            await refreshPreviewLoop()
        }
        .sheet(item: $exportFile) { file in
            LogShareSheet(fileURL: file.url)
        }
        .confirmationDialog(
            "清空日志？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                // 清空是同步磁盘 API：等后台任务删完再重置页面快照，避免主线程做 IO。
                Task { @MainActor in
                    previewGeneration += 1
                    await model.clearLogs()
                    // 磁盘与内存都被清空：快照必须一起重置，否则下一次合并又把旧记录带回来。
                    storedSnapshot = []
                    records = []
                    hasLoadedStoredSnapshot = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            // R7：只说后果，不写安抚句。
            Text("将删除本机保存的全部日志记录，不可恢复。")
        }
    }

    // MARK: - 日志状态

    private var statusSection: some View {
        PIGroup("日志状态") {
            PIFormRow {
                Toggle("启用日志", isOn: loggingEnabledBinding)
                    .font(PIFont.body)
                    .tint(PIColor.accent)
                    .accessibilityIdentifier("logs.toggleEnabled")
            }
            // 关闭后不是「没有日志」，而是「不再新增、历史仍可看可导出」：
            // 这条提示放在开关下方，避免用户把「不再记录」误解成「记录被清空」。
            if !model.logConfiguration.isEnabled {
                PIFormRow {
                    Text("已关闭：不再新增，已有记录保留且可导出")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("logs.disabledNotice")
                }
            }
            PIFormRow(showsDivider: false) {
                HStack(spacing: PISpacing.s8) {
                    Text("最近记录")
                        .font(PIFont.listTitle)
                        .foregroundStyle(PIColor.text)
                    Spacer(minLength: PISpacing.s8)
                    Text("\(records.count) 条")
                        .font(PIFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("logs.countText")
                }
            }
        }
    }

    private var loggingEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.logConfiguration.isEnabled },
            set: { model.setLoggingEnabled($0) }
        )
    }

    // MARK: - 日志等级

    private var levelSection: some View {
        PIGroup("日志等级") {
            ForEach(Array(PILogLevel.allCases.enumerated()), id: \.element.id) { index, level in
                PIOptionRow(
                    title: level.title,
                    subtitle: level.detail,
                    isSelected: model.logConfiguration.level == level,
                    showsDivider: index < PILogLevel.allCases.count - 1
                ) {
                    model.setLogLevel(level)
                }
                .accessibilityIdentifier("logs.level.\(level.rawValue)")
            }
        }
    }

    // MARK: - 时间格式

    private var timeFormatSection: some View {
        PIGroup("时间格式") {
            ForEach(Array(PILogTimeFormat.allCases.enumerated()), id: \.element.id) { index, format in
                PIOptionRow(
                    title: format.title,
                    isSelected: model.logConfiguration.timeFormat == format,
                    showsDivider: index < PILogTimeFormat.allCases.count - 1
                ) {
                    model.setLogTimeFormat(format)
                }
                .accessibilityIdentifier("logs.timeFormat.\(format.rawValue)")
            }
        }
    }

    // MARK: - 最近日志

    private var recentSection: some View {
        PIGroup("最近日志") {
            Text("日志不按条数截断；较早记录可能因容量轮转被淘汰。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PISpacing.s16)
                .padding(.top, PISpacing.s12)
                .accessibilityIdentifier("logs.capacityNotice")
            previewContainer
                .padding(.horizontal, PISpacing.s16)
                .padding(.top, PISpacing.s12)
                .padding(.bottom, PISpacing.s12)
        }
    }

    /// 固定高度的独立滚动区：日志再多也只占框内高度，不再把整页无限拉长。
    /// 空态与列表共用同一外框，保证空/非空切换时布局不跳动。
    private var previewContainer: some View {
        ScrollView {
            if records.isEmpty {
                Text("暂无日志")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
                    .accessibilityIdentifier("logs.emptyState")
            } else {
                previewRows
            }
        }
        .frame(height: 320)
        .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("logs.preview")
    }

    /// 全部可读记录按行惰性挂载；数据仍可能按既有磁盘容量规则轮转。
    private var previewRows: some View {
        LazyVStack(alignment: .leading, spacing: PISpacing.s4) {
            ForEach(records) { record in
                Text(formattedLine(record))
                    .font(PIFont.codeMono)
                    .foregroundStyle(levelColor(record.level))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contextMenu {
                        Button {
                            copySingleLine(record)
                        } label: {
                            Label("复制这一条", systemImage: "doc.on.doc")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PISpacing.s12)
        .padding(.vertical, PISpacing.s12)
        // 长按可直接选中任意一段日志文本（含跨行选择），配合每行的「复制这一条」。
        .textSelection(.enabled)
    }

    /// 列表与复制共用同一份格式化口径（时间格式切换后旧记录同样重新渲染）。
    private func formattedLine(_ record: PILogRecord) -> String {
        PILogFormatter.line(record, timeFormat: model.logConfiguration.timeFormat)
    }

    /// 复制单行：只写格式化后的这一行，不带任何元信息。
    private func copySingleLine(_ record: PILogRecord) {
        UIPasteboard.general.string = formattedLine(record)
        model.showToast("已复制这一条")
    }

    private func levelColor(_ level: PILogLevel) -> Color {
        switch level {
        case .debug: return PIColor.text2
        case .info: return PIColor.text
        case .warn: return PIColor.warning
        }
    }

    // MARK: - 导出

    private var exportSection: some View {
        PIGroup("导出") {
            PIFormRow {
                PIPrimaryButton(
                    title: "导出日志",
                    isEnabled: !isExporting,
                    identifier: "logs.export"
                ) {
                    Task { await exportLogs() }
                }
            }
            PIFormRow(showsDivider: false) {
                PISecondaryButton(title: "复制全部日志", isEnabled: !isExporting) {
                    Task { await copyAllLogs() }
                }
                .accessibilityIdentifier("logs.copyAll")
            }
        }
    }

    @MainActor
    private func exportLogs() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        let text = await model.exportLogText()
        // 导出文本可能到 MB 级：写盘同样放后台，不占用主线程。
        let result = await Task.detached(priority: .utility) {
            Result { try LogExportFileWriter.write(text) }
        }.value
        switch result {
        case .success(let url):
            exportFile = LogExportFile(url: url)
        case .failure(let error):
            model.showToast("导出失败：\(error.localizedDescription)")
        }
    }

    /// 复制全部日志：内容与导出的 txt 完全一致（含元信息头），直接写入系统剪贴板。
    @MainActor
    private func copyAllLogs() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        let text = await model.exportLogText()
        UIPasteboard.general.string = text
        model.showToast("日志已复制")
    }

    // 写盘细节见文件底部 `LogExportFileWriter`（nonisolated，供后台线程调用）。

    // MARK: - 清空

    private var clearSection: some View {
        PIGroup("清空") {
            PIDangerRow(title: "清空日志") {
                showingClearConfirmation = true
            }
            .accessibilityIdentifier("logs.clear")
        }
    }

    // MARK: - 刷新

    @MainActor
    private func refreshPreviewLoop() async {
        while !Task.isCancelled {
            refreshPreview()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    @MainActor
    private func refreshPreview() {
        // 合并而不是覆盖：重启后内存只有新记录、关闭日志后内存为空，
        // 单独用内存会把磁盘历史从列表里抹掉。省略 limit，保留全部当前可读记录。
        let merged = PILogRecordMerge.merge(
            stored: storedSnapshot,
            recent: model.currentLogRecords()
        )
        // 每秒刷新但只有内容真的变了才重绘，避免无谓的视图更新。
        guard merged != records else { return }
        records = merged
    }
}

/// 导出 txt 的写盘工具。放在 View 外并标 nonisolated，才能安全地在 `Task.detached` 里调用。
enum LogExportFileWriter {
    private static let filePrefix = "piios-log-"

    /// 写临时 txt（UTF-8）。每次导出前清掉上一次留下的导出文件，避免 tmp 累积。
    static func write(_ text: String) throws -> URL {
        // DateFormatter 在后台线程本地构造：不跨线程共享非 Sendable 的静态值。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(filePrefix)\(formatter.string(from: Date())).txt"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let directory = fileURL.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(filePrefix)
            && entry.pathExtension == "txt"
            && entry != fileURL {
            try? FileManager.default.removeItem(at: entry)
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

/// 待分享的导出文件；`sheet(item:)` 需要 Identifiable。
private struct LogExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系统分享面板：导出 txt 时交给用户选择「文件」/AirDrop/邮件（契约 §6）。
private struct LogShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
