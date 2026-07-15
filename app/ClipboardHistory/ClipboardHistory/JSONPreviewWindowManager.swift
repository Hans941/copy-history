import SwiftUI
import AppKit

struct JSONPreviewPayload: Equatable {
    let title: String
    let content: String
}

enum JSONPreviewSearch {
    static func matchRanges(in text: String, keyword: String) -> [NSRange] {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return [] }

        let nsText = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while true {
            let foundRange = nsText.range(of: trimmedKeyword, options: [.caseInsensitive], range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }
            ranges.append(foundRange)
            let nextLocation = foundRange.location + foundRange.length
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        return ranges
    }
}

final class JSONPreviewWindowManager: NSObject, NSWindowDelegate {
    static let shared = JSONPreviewWindowManager()

    private var window: NSWindow?

    var currentWindow: NSWindow? {
        window
    }

    var isKeyWindowActive: Bool {
        window?.isKeyWindow == true
    }

    func show(payload: JSONPreviewPayload) {
        let window = window ?? makeWindow()
        let hostingController = NSHostingController(
            rootView: JSONPreviewWindowView(payload: payload) { [weak self] in
                self?.close()
            }
        )

        window.contentViewController = hostingController
        window.title = payload.title.isEmpty ? "JSON 预览" : "JSON 预览 - \(payload.title)"
        center(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return window.frame.contains(point)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.titleVisibility = .visible
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.center()
        return window
    }

    private func center(window: NSWindow) {
        let targetScreen = PanelWindowManager.shared.currentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

private struct JSONPreviewWindowView: View {
    let payload: JSONPreviewPayload
    let onClose: () -> Void

    @State private var searchText: String = ""
    @State private var currentMatchIndex: Int = 0
    @State private var matchCount: Int = 0
    @State private var lastSubmittedSearchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("JSON 预览")
                    .font(.headline)
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索关键字", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit {
                            submitSearch()
                        }
                    Text(searchStatusText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 64, alignment: .trailing)
                    Button {
                        moveToPreviousMatch()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(matchCount == 0)
                    Button {
                        moveToNextMatch()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(matchCount == 0)
                }
            }

            SearchableJSONTextView(
                text: payload.content,
                searchText: searchText,
                currentMatchIndex: $currentMatchIndex,
                matchCount: $matchCount
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button("关闭") {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: searchText) {
            currentMatchIndex = 0
            lastSubmittedSearchText = ""
        }
        .onChange(of: matchCount) { _, newValue in
            if newValue == 0 {
                currentMatchIndex = 0
            } else if currentMatchIndex >= newValue {
                currentMatchIndex = newValue - 1
            }
        }
    }

    private var searchStatusText: String {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        guard matchCount > 0 else { return "无结果" }
        return "\(currentMatchIndex + 1)/\(matchCount)"
    }

    private func moveToPreviousMatch() {
        guard matchCount > 0 else { return }
        lastSubmittedSearchText = searchText
        currentMatchIndex = (currentMatchIndex - 1 + matchCount) % matchCount
    }

    private func moveToNextMatch() {
        guard matchCount > 0 else { return }
        lastSubmittedSearchText = searchText
        currentMatchIndex = (currentMatchIndex + 1) % matchCount
    }

    private func submitSearch() {
        guard matchCount > 0 else { return }

        if lastSubmittedSearchText != searchText {
            lastSubmittedSearchText = searchText
            currentMatchIndex = 0
            return
        }

        moveToNextMatch()
    }
}

private struct SearchableJSONTextView: NSViewRepresentable {
    let text: String
    let searchText: String
    @Binding var currentMatchIndex: Int
    @Binding var matchCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        update(textView: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        update(textView: textView, coordinator: context.coordinator)
    }

    private func update(textView: NSTextView, coordinator: Coordinator) {
        let matches = coordinator.matches(for: text, searchText: searchText)

        var safeCurrentMatchIndex = currentMatchIndex
        if matches.isEmpty {
            safeCurrentMatchIndex = 0
        } else {
            safeCurrentMatchIndex = min(max(safeCurrentMatchIndex, 0), matches.count - 1)
        }

        guard coordinator.shouldRender(
            text: text,
            searchText: searchText,
            currentMatchIndex: safeCurrentMatchIndex,
            matchCount: matches.count
        ) else {
            return
        }

        let attributedText = coordinator.baseAttributedText(for: text, searchText: searchText)
        if !matches.isEmpty {
            attributedText.addAttribute(
                .backgroundColor,
                value: NSColor.systemOrange.withAlphaComponent(0.36),
                range: matches[safeCurrentMatchIndex]
            )
        }

        textView.textStorage?.setAttributedString(attributedText)

        if !matches.isEmpty {
            let currentMatchRange = matches[safeCurrentMatchIndex]
            textView.setSelectedRange(currentMatchRange)
            revealMatch(
                currentMatchRange,
                in: textView,
                fullText: text
            )
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(NSPoint(x: 0, y: 0))
        }

        coordinator.recordRenderedState(
            text: text,
            searchText: searchText,
            currentMatchIndex: safeCurrentMatchIndex,
            matchCount: matches.count
        )

        DispatchQueue.main.async {
            if self.matchCount != matches.count {
                self.matchCount = matches.count
            }
            if self.currentMatchIndex != safeCurrentMatchIndex {
                self.currentMatchIndex = safeCurrentMatchIndex
            }
        }
    }

    private func revealMatch(_ range: NSRange, in textView: NSTextView, fullText: String) {
        guard
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let scrollView = textView.enclosingScrollView
        else {
            textView.scrollRangeToVisible(range)
            return
        }

        let focusRange = (fullText as NSString).lineRange(for: range)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y

        let paddedRect = rect.insetBy(dx: -32, dy: -56)
        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let maxOffsetX = max(0, textView.bounds.width - visibleSize.width)
        let maxOffsetY = max(0, textView.bounds.height - visibleSize.height)

        let targetOrigin = NSPoint(
            x: min(max(0, paddedRect.midX - visibleSize.width / 2), maxOffsetX),
            y: min(max(0, paddedRect.midY - visibleSize.height / 2), maxOffsetY)
        )

        clipView.scroll(to: targetOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    final class Coordinator {
        private var cachedText: String = ""
        private var cachedSearchText: String = ""
        private var cachedMatches: [NSRange] = []
        private var cachedBaseAttributedText = NSMutableAttributedString(string: "")

        private var lastRenderedText: String = ""
        private var lastRenderedSearchText: String = ""
        private var lastRenderedMatchIndex: Int = -1
        private var lastRenderedMatchCount: Int = -1

        func matches(for text: String, searchText: String) -> [NSRange] {
            if cachedText == text, cachedSearchText == searchText {
                return cachedMatches
            }

            cachedText = text
            cachedSearchText = searchText
            cachedMatches = JSONPreviewSearch.matchRanges(in: text, keyword: searchText)

            let attributedText = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]
            )

            for range in cachedMatches {
                attributedText.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.22),
                    range: range
                )
            }
            cachedBaseAttributedText = attributedText
            return cachedMatches
        }

        func baseAttributedText(for text: String, searchText: String) -> NSMutableAttributedString {
            _ = matches(for: text, searchText: searchText)
            return cachedBaseAttributedText.mutableCopy() as? NSMutableAttributedString
                ?? NSMutableAttributedString(attributedString: cachedBaseAttributedText)
        }

        func shouldRender(text: String, searchText: String, currentMatchIndex: Int, matchCount: Int) -> Bool {
            lastRenderedText != text ||
            lastRenderedSearchText != searchText ||
            lastRenderedMatchIndex != currentMatchIndex ||
            lastRenderedMatchCount != matchCount
        }

        func recordRenderedState(text: String, searchText: String, currentMatchIndex: Int, matchCount: Int) {
            lastRenderedText = text
            lastRenderedSearchText = searchText
            lastRenderedMatchIndex = currentMatchIndex
            lastRenderedMatchCount = matchCount
        }
    }
}
