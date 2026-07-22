import SwiftUI
import AppKit
import Carbon

struct ContentView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var isPanelVisible: Bool
    @FocusState private var searchFocused: Bool
    @State private var editingEntry: ClipboardEntry?
    @State private var editedText: String = ""
    @State private var editedNote: String = ""
    @State private var showSettings = false
    @State private var timestampFormatDraft: String = ""
    @State private var timeZoneIdentifierDraft: String = ""
    @State private var siteInfoDataFilePathDraft: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var outsideClickMonitor: Any?
    @State private var showClearNonFavoritesConfirmation = false
    @State private var previousSearchInputSourceID: String?
    @StateObject private var keyMonitor = PanelKeyMonitor()
    @Environment(\.colorScheme) private var colorScheme

    private let cardSize = CGSize(width: 220, height: 170)
    private let cardSpacing: CGFloat = 18
    private let listHorizontalPadding: CGFloat = 4

    private var panelBackgroundColor: Color {
        Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.97 : 0.98)
    }

    private var surfaceBackgroundColor: Color {
        Color(nsColor: .textBackgroundColor)
    }

    private var controlSurfaceColor: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var chipSelectedBackground: Color {
        controlSurfaceColor.opacity(colorScheme == .dark ? 0.9 : 1.0)
    }

    private var panelStrokeColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    private var cardHighlightBackground: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)
    }

    private var preferredPanelColorScheme: ColorScheme? {
        switch viewModel.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        panelBody
            .background(PanelWindowConfigurator())
            .alert("提示", isPresented: $viewModel.showingAlert, actions: {
                Button("好", role: .cancel) {}
            }, message: {
                Text(viewModel.alertMessage)
            })
            .sheet(item: $editingEntry) { entry in
                editSheet(entry: entry)
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
            .confirmationDialog(
                "仅保留收藏？",
                isPresented: $showClearNonFavoritesConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空非收藏记录", role: .destructive) {
                    viewModel.clearNonFavorites()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有未收藏的剪贴记录，并同步清理对应图片文件。此操作不可撤销。")
            }
            .onAppear {
                PanelWindowManager.shared.repositionToFocusedScreen(animated: false)
                PanelWindowManager.shared.setVisibility(isPanelVisible)
                keyMonitor.start { event in
                    handleKey(event: event)
                }
                updateDismissMonitors(visible: isPanelVisible)
            }
            .onDisappear {
                keyMonitor.stop()
                updateDismissMonitors(visible: false)
            }
            .onChange(of: isPanelVisible) { newValue in
                PanelWindowManager.shared.setVisibility(newValue)
                if newValue {
                    resetSelectionState()
                    PanelWindowManager.shared.repositionToFocusedScreen()
                } else {
                    resetTransientState()
                }
                updateDismissMonitors(visible: newValue)
            }
            .onChange(of: viewModel.searchText) { _ in
                highlightedIndex = 0
            }
            .onChange(of: viewModel.selectedTab) { _ in
                highlightedIndex = 0
            }
            .onChange(of: searchFocused) { focused in
                updateSearchInputSource(focused: focused)
            }
            .onReceive(NotificationCenter.default.publisher(for: .presentSettingsSheet)) { _ in
                showSettings = true
            }
            .preferredColorScheme(preferredPanelColorScheme)
    }

    private var panelBody: some View {
        VStack(spacing: 14) {
            toolbar
            contentList
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(panelStrokeColor, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 14)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var toolbar: some View {
        HStack(alignment: .center, spacing: 16) {
            searchBar
                .layoutPriority(1)
            tabChips
            Spacer(minLength: 12)
            toolbarButtons
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索历史或备注", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
                .focused($searchFocused)
                .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
                    searchFocused = true
                }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(surfaceBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(minWidth: 260, maxWidth: 360)
    }

    private var tabChips: some View {
        HStack(spacing: 8) {
            ForEach(ClipboardTab.displayTabs) { tab in
                chip(for: tab)
            }
        }
    }

    private func chip(for tab: ClipboardTab) -> some View {
        Button {
            viewModel.selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(chipColor(for: tab))
                    .frame(width: 8, height: 8)
                Text(tab.displayName)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(tab == viewModel.selectedTab ? chipSelectedBackground : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chipColor(for tab: ClipboardTab) -> Color {
        switch tab {
        case .favorite:
            return Color.orange
        default:
            return Color.red.opacity(0.8)
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 10) {
            toolbarButton(systemName: "square.and.arrow.down", title: "捕获当前剪贴板") {
                viewModel.captureClipboardOnce()
            }
            toolbarButton(systemName: "trash", title: "仅保留收藏") {
                showClearNonFavoritesConfirmation = true
            }
            toolbarButton(systemName: "gearshape", title: "设置") {
                showSettings = true
            }
            toolbarButton(systemName: "xmark.circle", title: "隐藏面板") {
                dismissPanel(reason: "button")
            }
        }
    }

    private func toolbarButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 30, height: 30)
                .background(surfaceBackgroundColor)
                .clipShape(Circle())
                .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var contentList: some View {
        Group {
            if viewModel.filteredEntries.isEmpty {
                emptyState
            } else {
                NativeHorizontalCardList(
                    items: viewModel.filteredEntries,
                    highlightedIndex: highlightedIndex,
                    cardHeight: cardSize.height,
                    cardWidth: cardSize.width,
                    cardSpacing: cardSpacing,
                    horizontalPadding: listHorizontalPadding
                ) { _, entry, isHighlighted in
                    AnyView(
                        entryCard(entry, isHighlighted: isHighlighted)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                select(entry: entry)
                            }
                            .contextMenu {
                                if entry.type == .text {
                                    Button("编辑") {
                                        presentEdit(entry: entry)
                                    }
                                    if entry.isJSONText {
                                        Button("JSON 预览") {
                                            presentJSONPreview(for: entry)
                                        }
                                    }
                                    if entry.developerMetadata?.hasSiteContext == true {
                                        Button("复制 site 信息") {
                                            viewModel.openSiteInfoAction(for: entry)
                                        }
                                    }
                                }
                                Button(entry.isFavorite ? "取消收藏" : "收藏") {
                                    viewModel.toggleFavorite(for: entry)
                                }
                                Button("复制") {
                                    viewModel.copyToPasteboard(entry: entry)
                                }
                                Divider()
                                Button(role: .destructive) {
                                    viewModel.delete(entry: entry)
                                } label: {
                                    Text("删除")
                                }
                            }
                    )
                }
                .onAppear {
                    clampHighlightedIndex()
                }
                .onChange(of: viewModel.filteredEntries) { _ in
                    clampHighlightedIndex()
                }
                .frame(height: cardSize.height + 32)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("暂无剪贴记录，复制一些文本或图片试试")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: cardSize.height + 32)
    }

    private func entryCard(_ entry: ClipboardEntry, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            if entry.type == .text {
                Text(entry.previewText)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let formattedTimestampText = entry.formattedTimestampText {
                    Label(formattedTimestampText, systemImage: "clock")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let developerMetadata = entry.developerMetadata {
                    developerMetadataSummary(developerMetadata)
                }
            } else {
                cardImage(for: entry)
            }
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Text(entry.sourceApp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: cardSize.width, height: cardSize.height)
        .background(isHighlighted ? cardHighlightBackground : surfaceBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(isHighlighted ? 0.2 : 0.08), radius: 10, y: 5)
    }

    private func cardImage(for entry: ClipboardEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
            if let path = entry.imagePath,
               let nsImage = viewModel.image(for: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("图片预览不可用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 110)
    }

    private func developerMetadataSummary(_ metadata: ClipboardDeveloperMetadata) -> some View {
        Label(metadata.summaryText, systemImage: "curlybraces.square")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.headline)
            Stepper(value: Binding(
                get: { viewModel.settings.historyLimit },
                set: { viewModel.updateHistoryLimit($0) }), in: 1000...10000, step: 500) {
                Text("历史上限：\(viewModel.settings.historyLimit)")
            }
            Stepper(value: Binding(
                get: { viewModel.settings.imageQuotaMB },
                set: { viewModel.updateImageQuota($0) }), in: 256...4096, step: 256) {
                Text("图片配额(MB)：\(viewModel.settings.imageQuotaMB)")
            }
            Picker("主题", selection: Binding(
                get: { viewModel.settings.theme },
                set: { viewModel.updateTheme($0) })) {
                Text("自动").tag("auto")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("时间戳显示")
                    .font(.subheadline.weight(.medium))
                TextField("时间格式，例如 yyyy/MM/dd HH:mm:ss", text: $timestampFormatDraft)
                TextField("时区标识，例如 Asia/Shanghai", text: $timeZoneIdentifierDraft)
                Text("默认格式：yyyy/MM/dd HH:mm:ss。时区无效时会回退到当前电脑时区。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("site-info 数据")
                    .font(.subheadline.weight(.medium))
                TextField("site-info JSON 文件路径，留空则只展示识别到的 app_local/site_id", text: $siteInfoDataFilePathDraft)
                Text("JSON 数组字段支持 app_local、site_id、site_name、shop_type、idc、tenant_id、area_id。配置后复制 app_local 或 site_id 会补全站点、出口和租户信息。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("完成") {
                saveSettingsDrafts()
                showSettings = false
            }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .frame(minWidth: 420)
        .onAppear {
            loadSettingDrafts()
        }
    }

    private func editSheet(entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑文本")
                .font(.headline)
            TextEditor(text: $editedText)
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            TextField("备注", text: $editedNote)
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    editingEntry = nil
                }
                Button("保存") {
                    if let editingEntry {
                        viewModel.update(entry: editingEntry, newText: editedText, note: editedNote)
                    }
                    editingEntry = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            editedText = entry.text ?? ""
            editedNote = entry.note
        }
    }

    private func presentEdit(entry: ClipboardEntry) {
        editingEntry = entry
    }

    private func presentJSONPreview(for entry: ClipboardEntry) {
        guard let content = viewModel.jsonPreview(for: entry) else {
            return
        }
        JSONPreviewWindowManager.shared.show(
            payload: JSONPreviewPayload(title: entry.previewText, content: content)
        )
    }

    private func loadSettingDrafts() {
        timestampFormatDraft = viewModel.settings.timestampDisplayFormat
        timeZoneIdentifierDraft = viewModel.settings.timestampTimeZoneIdentifier
        siteInfoDataFilePathDraft = viewModel.settings.siteInfoDataFilePath
    }

    private func saveSettingsDrafts() {
        viewModel.updateTimestampDisplayFormat(timestampFormatDraft)
        viewModel.updateTimestampTimeZoneIdentifier(timeZoneIdentifierDraft)
        viewModel.updateSiteInfoDataFilePath(siteInfoDataFilePathDraft)
    }

    private func handleKey(event: NSEvent) -> Bool {
        guard isPanelVisible else { return false }
        guard !JSONPreviewWindowManager.shared.isKeyWindowActive else { return false }
        switch event.keyCode {
        case 123: // left
            moveSelection(by: -1)
            return true
        case 124: // right
            moveSelection(by: 1)
            return true
        case 125: // down
            moveSelection(by: 1)
            return true
        case 126: // up
            moveSelection(by: -1)
            return true
        case 36: // return
            triggerSelection()
            return true
        case 53: // esc
            dismissPanel(reason: "esc")
            return true
        default:
            return false
        }
    }

    private func moveSelection(by offset: Int) {
        let items = viewModel.filteredEntries
        guard !items.isEmpty else { return }
        var newIndex = highlightedIndex + offset
        newIndex = min(max(newIndex, 0), items.count - 1)
        withAnimation(.easeInOut(duration: 0.18)) {
            highlightedIndex = newIndex
        }
    }

    private func triggerSelection() {
        let items = viewModel.filteredEntries
        guard highlightedIndex >= 0, highlightedIndex < items.count else { return }
        select(entry: items[highlightedIndex])
    }

    private func select(entry: ClipboardEntry) {
        viewModel.copyToPasteboard(entry: entry, showAlert: false)
        dismissPanel(reason: "select")
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    private func resetSelectionState() {
        highlightedIndex = 0
    }

    private func resetTransientState() {
        highlightedIndex = 0
        viewModel.searchText = ""
        viewModel.showingAlert = false
        editingEntry = nil
        editedText = ""
        editedNote = ""
        showSettings = false
        searchFocused = false
        restorePreviousSearchInputSource()
        loadSettingDrafts()
        JSONPreviewWindowManager.shared.close()
    }

    private func updateSearchInputSource(focused: Bool) {
        if focused {
            previousSearchInputSourceID = currentKeyboardInputSourceID()
            selectKeyboardInputSource(id: "com.apple.keylayout.ABC")
        } else {
            restorePreviousSearchInputSource()
        }
    }

    private func restorePreviousSearchInputSource() {
        if let previousSearchInputSourceID {
            selectKeyboardInputSource(id: previousSearchInputSourceID)
            self.previousSearchInputSourceID = nil
        }
    }

    private func currentKeyboardInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private func selectKeyboardInputSource(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else {
            return
        }
        TISSelectInputSource(source)
    }

    private func updateDismissMonitors(visible: Bool) {
        if visible {
            startOutsideClickMonitor()
        } else {
            stopOutsideClickMonitor()
        }
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if !isPanelVisible { return }
            handleOutsideClick(event)
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard let window = PanelWindowManager.shared.currentWindow else { return }
        let location = eventScreenLocation(for: event)
        if JSONPreviewWindowManager.shared.containsScreenPoint(location) {
            return
        }
        let windowLocation = window.convertPoint(fromScreen: location)
        let windowBounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.frame.size)
        if !windowBounds.contains(windowLocation) {
            dismissPanel(reason: "outside_click")
        }
    }

    private func eventScreenLocation(for event: NSEvent) -> NSPoint {
        if let eventWindow = event.window {
            return eventWindow.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    private func dismissPanel(reason: String) {
        DispatchQueue.main.async {
            isPanelVisible = false
            ClipLog.info("dismiss_panel reason=\(reason)")
        }
    }

    private func clampHighlightedIndex() {
        let count = viewModel.filteredEntries.count
        guard count > 0 else {
            highlightedIndex = 0
            return
        }
        if highlightedIndex >= count {
            highlightedIndex = count - 1
        } else if highlightedIndex < 0 {
            highlightedIndex = 0
        }
    }
}

struct NativeHorizontalCardList<Item: Identifiable>: NSViewRepresentable {
    let items: [Item]
    let highlightedIndex: Int
    let cardHeight: CGFloat
    let cardWidth: CGFloat
    let cardSpacing: CGFloat
    let horizontalPadding: CGFloat
    let itemView: (Int, Item, Bool) -> AnyView

    private var itemCount: Int {
        items.count
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> HorizontalDragScrollView {
        let scrollView = HorizontalDragScrollView()
        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = hostingView

        context.coordinator.attach(scrollView: scrollView, hostingView: hostingView)
        context.coordinator.update(parent: self)
        context.coordinator.updateVisibleRangeIfNeeded(force: true)
        context.coordinator.refreshContentLayout()
        context.coordinator.scrollToHighlighted(animated: false, force: true)
        return scrollView
    }

    func updateNSView(_ nsView: HorizontalDragScrollView, context: Context) {
        context.coordinator.update(parent: self)
        context.coordinator.updateVisibleRangeIfNeeded(force: true)
        context.coordinator.refreshContentLayout()
        context.coordinator.scrollToHighlightedIfNeeded(animated: true)
    }

    final class Coordinator: NSObject {
        private var parent: NativeHorizontalCardList
        private weak var scrollView: HorizontalDragScrollView?
        private var hostingView: NSHostingView<AnyView>?
        private var boundsObserver: NSObjectProtocol?
        private var visibleRange: ClosedRange<Int>?
        private var lastAutoScrolledHighlight: Int?
        private var lastAutoScrolledItemCount: Int?

        init(parent: NativeHorizontalCardList) {
            self.parent = parent
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func update(parent: NativeHorizontalCardList) {
            self.parent = parent
        }

        func attach(scrollView: HorizontalDragScrollView, hostingView: NSHostingView<AnyView>) {
            self.scrollView = scrollView
            self.hostingView = hostingView
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updateVisibleRangeIfNeeded(force: false)
            }
        }

        func refreshContentLayout() {
            guard let hostingView, let scrollView else { return }
            let width = totalDocumentWidth
            let height = max(parent.cardHeight + 12, scrollView.contentSize.height)
            hostingView.frame = NSRect(origin: .zero, size: CGSize(width: width, height: height))
        }

        func scrollToHighlightedIfNeeded(animated: Bool) {
            guard lastAutoScrolledHighlight != parent.highlightedIndex || lastAutoScrolledItemCount != parent.itemCount else {
                return
            }
            scrollToHighlighted(animated: animated, force: false)
        }

        func scrollToHighlighted(animated: Bool, force: Bool) {
            guard let scrollView, parent.itemCount > 0 else { return }
            guard parent.highlightedIndex >= 0, parent.highlightedIndex < parent.itemCount else { return }
            guard force || !scrollView.isUserInteracting else { return }

            let itemStride = parent.cardWidth + parent.cardSpacing
            let itemCenterX = parent.horizontalPadding + parent.cardWidth / 2 + CGFloat(parent.highlightedIndex) * itemStride
            let visibleWidth = scrollView.contentView.bounds.width
            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            let maxOffset = max(0, documentWidth - visibleWidth)
            let targetOffset = min(max(itemCenterX - visibleWidth / 2, 0), maxOffset)

            lastAutoScrolledHighlight = parent.highlightedIndex
            lastAutoScrolledItemCount = parent.itemCount
            guard abs(scrollView.contentView.bounds.origin.x - targetOffset) > 1 else { return }

            scrollView.setHorizontalOffset(targetOffset, animated: animated)
        }

        func updateVisibleRangeIfNeeded(force: Bool) {
            guard let hostingView else { return }
            let nextRange = computedVisibleRange()
            guard force || nextRange != visibleRange else { return }
            visibleRange = nextRange
            hostingView.rootView = renderedContent(for: nextRange)
        }

        private var totalDocumentWidth: CGFloat {
            guard parent.itemCount > 0 else { return parent.horizontalPadding * 2 }
            return parent.horizontalPadding * 2
                + CGFloat(parent.itemCount) * parent.cardWidth
                + CGFloat(max(0, parent.itemCount - 1)) * parent.cardSpacing
        }

        private func computedVisibleRange() -> ClosedRange<Int>? {
            guard let scrollView, parent.itemCount > 0 else { return nil }
            let itemStride = parent.cardWidth + parent.cardSpacing
            let visibleBounds = scrollView.contentView.bounds
            let buffer = itemStride * 2
            let minX = max(visibleBounds.minX - parent.horizontalPadding - buffer, 0)
            let maxX = max(visibleBounds.maxX - parent.horizontalPadding + buffer, 0)
            let lowerBound = max(Int(floor(minX / itemStride)), 0)
            let upperBound = min(Int(floor(maxX / itemStride)), parent.itemCount - 1)
            return lowerBound...max(lowerBound, upperBound)
        }

        private func renderedContent(for visibleRange: ClosedRange<Int>?) -> AnyView {
            AnyView(
                ZStack(alignment: .topLeading) {
                    if let visibleRange {
                        ForEach(Array(visibleRange), id: \.self) { index in
                            self.parent.itemView(index, self.parent.items[index], index == self.parent.highlightedIndex)
                                .offset(
                                    x: self.parent.horizontalPadding + CGFloat(index) * (self.parent.cardWidth + self.parent.cardSpacing),
                                    y: 6
                                )
                        }
                    }
                }
                .frame(width: totalDocumentWidth, height: self.parent.cardHeight + 12, alignment: .topLeading)
            )
        }
    }
}

final class HorizontalDragScrollView: NSScrollView {
    private var dragStartOffset: CGFloat = 0
    private var interactionResetWorkItem: DispatchWorkItem?
    private(set) var isUserInteracting = false
    private lazy var panGestureRecognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        let delta = abs(horizontalDelta) > abs(verticalDelta) ? horizontalDelta : verticalDelta
        guard delta != 0 else {
            super.scrollWheel(with: event)
            return
        }
        beginUserInteraction()
        let amount: CGFloat
        if event.hasPreciseScrollingDeltas {
            amount = CGFloat(delta)
        } else {
            let scrollUnit = max(horizontalLineScroll, 10)
            amount = CGFloat(delta) * scrollUnit
        }
        setHorizontalOffset(contentView.bounds.origin.x - amount, animated: false)
    }

    func setHorizontalOffset(_ proposedOffset: CGFloat, animated: Bool) {
        let clampedOffset = clamp(offset: proposedOffset)
        let targetPoint = NSPoint(x: clampedOffset, y: 0)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                contentView.animator().setBoundsOrigin(targetPoint)
            }
        } else {
            contentView.scroll(to: targetPoint)
            reflectScrolledClipView(contentView)
        }
    }

    private func configure() {
        wantsLayer = true
        addGestureRecognizer(panGestureRecognizer)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginUserInteraction()
            dragStartOffset = contentView.bounds.origin.x
        case .changed:
            beginUserInteraction()
            let translation = recognizer.translation(in: self)
            setHorizontalOffset(dragStartOffset - translation.x, animated: false)
        case .ended, .cancelled, .failed:
            endUserInteractionSoon()
        default:
            break
        }
    }

    private func beginUserInteraction() {
        guard !isUserInteracting else {
            endUserInteractionSoon()
            return
        }
        isUserInteracting = true
        endUserInteractionSoon()
    }

    private func endUserInteractionSoon() {
        interactionResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isUserInteracting else { return }
            self.isUserInteracting = false
        }
        interactionResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func clamp(offset: CGFloat) -> CGFloat {
        let documentWidth = documentView?.bounds.width ?? 0
        let visibleWidth = contentView.bounds.width
        let maxOffset = max(0, documentWidth - visibleWidth)
        return min(max(offset, 0), maxOffset)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: ClipboardHistoryViewModel(),
                    isPanelVisible: .constant(true))
    }
}
