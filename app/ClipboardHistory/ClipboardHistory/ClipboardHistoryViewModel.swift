import SwiftUI
import AppKit
import CryptoKit
import Combine

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    private static let imageCache = NSCache<NSString, NSImage>()
    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet {
            entriesVersion &+= 1
            rebuildSearchIndex()
            refreshFilteredEntries(forcePublish: true)
        }
    }
    @Published private(set) var filteredEntries: [ClipboardEntry] = []
    private(set) var entriesVersion = 0
    private(set) var filteredEntriesVersion = 0
    @Published var settings: ClipboardSettings
    @Published var searchText: String = "" {
        didSet { scheduleSearchRefresh() }
    }
    @Published var selectedTab: ClipboardTab = .clipboardHistory {
        didSet { refreshFilteredEntries() }
    }
    @Published var showingAlert: Bool = false
    @Published var alertMessage: String = ""

    let store: ClipboardHistoryPersisting
    private let settingsManager: SettingsManaging
    private let watcher: ClipboardWatching
    private var cancellables: Set<AnyCancellable> = []
    private var lastCapturedFingerprint: String?
    private var lastCaptureDate: Date?
    private var ignoredPasteboardFingerprints: [String: Date] = [:]
    private let ignoredPasteboardFingerprintTTL: TimeInterval = 5
    private var searchIndex: [UUID: String] = [:]
    private var searchRefreshTask: Task<Void, Never>?
    private let searchRefreshDelayNanoseconds: UInt64 = 80_000_000

    init(store: ClipboardHistoryPersisting = ClipboardHistoryStore(),
         watcher: ClipboardWatching = ClipboardWatcher(),
         settingsManager: SettingsManaging = SettingsManager.shared) {
        self.store = store
        self.watcher = watcher
        self.settingsManager = settingsManager
        self.settings = settingsManager.current
        self.watcher.onCapture = { [weak self] snapshot in
            Task { @MainActor in
                self?.handle(snapshot: snapshot)
            }
        }
        Task {
            await loadInitialEntries()
            watcher.start()
        }
        settingsManager.settingsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                let shouldRefreshDerivedMetadata =
                    self.settings.timestampDisplayFormat != value.timestampDisplayFormat ||
                    self.settings.timestampTimeZoneIdentifier != value.timestampTimeZoneIdentifier
                self.settings = value
                if shouldRefreshDerivedMetadata {
                    self.refreshDerivedMetadata()
                }
            }
            .store(in: &cancellables)
    }

    private static func buildFilteredEntries(
        entries: [ClipboardEntry],
        searchText: String,
        selectedTab: ClipboardTab,
        searchIndex: [UUID: String]
    ) -> [ClipboardEntry] {
        let normalizedKeyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return entries.filter { entry in
            guard matchesTab(for: entry, selectedTab: selectedTab) else { return false }
            guard !normalizedKeyword.isEmpty else { return true }

            return searchIndex[entry.id]?.contains(normalizedKeyword) == true
        }
    }

    private static func matchesTab(for entry: ClipboardEntry, selectedTab: ClipboardTab) -> Bool {
        switch selectedTab {
        case .favorite:
            return entry.isFavorite
        case .clipboardHistory:
            return !entry.isFavorite
        default:
            return entry.tab == selectedTab
        }
    }

    private func refreshFilteredEntries() {
        refreshFilteredEntries(forcePublish: false)
    }

    private func refreshFilteredEntries(forcePublish: Bool) {
        let nextEntries = Self.buildFilteredEntries(
            entries: entries,
            searchText: searchText,
            selectedTab: selectedTab,
            searchIndex: searchIndex
        )

        guard forcePublish || !Self.haveSameEntryIDs(filteredEntries, nextEntries) else {
            return
        }
        filteredEntries = nextEntries
        filteredEntriesVersion &+= 1
    }

    private static func haveSameEntryIDs(_ left: [ClipboardEntry], _ right: [ClipboardEntry]) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { $0.id == $1.id }
    }

    func applySearchImmediately() {
        searchRefreshTask?.cancel()
        searchRefreshTask = nil
        refreshFilteredEntries()
    }

    private func scheduleSearchRefresh() {
        searchRefreshTask?.cancel()
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshFilteredEntries()
            return
        }
        searchRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: searchRefreshDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.refreshFilteredEntries()
        }
    }

    private func rebuildSearchIndex() {
        searchIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.searchIndexText) })
    }

    func captureClipboardOnce() {
        guard let snapshot = watcherCaptureFallback() else {
            displayAlert(message: "当前剪贴板不包含文本或图片")
            return
        }
        handle(snapshot: snapshot)
    }

    func toggleFavorite(for entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite.toggle()
        store.updateEntry(entries[index])
    }

    func deleteEntries(at offsets: IndexSet) {
        offsets.forEach { index in
            let entry = filteredEntries[index]
            remove(entryID: entry.id)
        }
    }

    func delete(entry: ClipboardEntry) {
        remove(entryID: entry.id)
    }

    func updateHistoryLimit(_ newValue: Int) {
        guard newValue != settings.historyLimit else { return }
        settingsManager.update { $0.historyLimit = newValue }
        settings.historyLimit = newValue
        Task {
            await loadInitialEntries(historyLimit: newValue, imageQuotaMB: settings.imageQuotaMB)
        }
    }

    func updateImageQuota(_ value: Int) {
        guard value != settings.imageQuotaMB else { return }
        settingsManager.update { $0.imageQuotaMB = value }
        settings.imageQuotaMB = value
        Task {
            await loadInitialEntries(historyLimit: settings.historyLimit, imageQuotaMB: value)
        }
    }

    func updateTheme(_ theme: String) {
        settingsManager.update { $0.theme = theme }
    }

    func updateTimestampDisplayFormat(_ format: String) {
        let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? "yyyy/MM/dd HH:mm:ss" : normalized
        guard value != settings.timestampDisplayFormat else { return }
        settingsManager.update { $0.timestampDisplayFormat = value }
        settings.timestampDisplayFormat = value
        refreshDerivedMetadata()
    }

    func updateTimestampTimeZoneIdentifier(_ identifier: String) {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.isEmpty ? TimeZone.current.identifier : normalized
        guard value != settings.timestampTimeZoneIdentifier else { return }
        settingsManager.update { $0.timestampTimeZoneIdentifier = value }
        settings.timestampTimeZoneIdentifier = value
        refreshDerivedMetadata()
    }

    func updateSiteInfoDataFilePath(_ path: String) {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != settings.siteInfoDataFilePath else { return }
        settingsManager.update { $0.siteInfoDataFilePath = value }
        settings.siteInfoDataFilePath = value
        refreshDerivedMetadata()
    }

    func update(entry: ClipboardEntry, newText: String, note: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        guard entries[index].type == .text else { return }
        entries[index].text = newText
        entries[index].note = note
        entries[index].timestamp = Date()
        entries[index] = applyingDerivedMetadata(to: entries[index])
        store.updateEntry(entries[index])
    }

    func jsonPreview(for entry: ClipboardEntry) -> String? {
        guard entry.type == .text, let text = entry.text else { return nil }
        return ClipboardTextAnalyzer.prettyPrintedJSON(from: text)
    }

    func openSiteInfoAction(for entry: ClipboardEntry) {
        guard let metadata = entry.developerMetadata,
              let action = ClipboardDeveloperActionBuilder.siteInfoAction(metadata: metadata) else {
            displayAlert(message: "未识别到 site 信息")
            return
        }
        performDeveloperAction(action)
    }

    func copyToPasteboard(entry: ClipboardEntry, showAlert: Bool = true) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.type {
        case .text:
            if let text = entry.text {
                pasteboard.setString(text, forType: .string)
                rememberInternalPasteboardWrite(.text(text))
                if showAlert {
                    displayAlert(message: "已复制到剪贴板")
                }
            }
        case .image:
            if let imageName = entry.imagePath,
               let image = image(for: imageName) {
                pasteboard.writeObjects([image])
                rememberInternalPasteboardWrite(.image(image))
                if showAlert {
                    displayAlert(message: "图片已复制")
                }
            } else {
                displayAlert(message: "图片已不存在")
            }
        }
    }

    func clearNonFavorites() {
        entries
            .filter { !$0.isFavorite && $0.type == .image }
            .compactMap(\.imagePath)
            .forEach { Self.imageCache.removeObject(forKey: $0 as NSString) }
        entries.removeAll { !$0.isFavorite }
        store.clearNonFavorites()
    }

    func imageURL(for imageName: String) -> URL? {
        (store as? ClipboardHistoryStore)?.imageURL(for: imageName)
    }

    func image(for imageName: String) -> NSImage? {
        let cacheKey = imageName as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let url = imageURL(for: imageName),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        Self.imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func loadInitialEntries(historyLimit: Int? = nil, imageQuotaMB: Int? = nil) async {
        let effectiveHistoryLimit = historyLimit ?? settings.historyLimit
        let effectiveImageQuota = imageQuotaMB ?? settings.imageQuotaMB
        store.enforceQuota(historyLimit: effectiveHistoryLimit, imageQuotaMB: effectiveImageQuota)
        entries = store.loadEntries(limit: effectiveHistoryLimit, offset: 0).map { applyingDerivedMetadata(to: $0) }
    }

    private func handle(snapshot: ClipboardSnapshot) {
        guard !shouldIgnore(snapshot: snapshot) else { return }
        switch snapshot.type {
        case .text(let string):
            let entry = ClipboardEntry(type: .text,
                                       text: string,
                                       isFavorite: false,
                                       tab: .clipboardHistory,
                                       note: "",
                                       sourceApp: snapshot.sourceApp)
            insert(entry: entry)
        case .image(let image):
            do {
                let imageName = try (store as? ClipboardHistoryStore)?.persistImage(image) ?? ""
                let entry = ClipboardEntry(type: .image,
                                           imagePath: imageName,
                                           isFavorite: false,
                                           tab: .clipboardHistory,
                                           note: "",
                                           sourceApp: snapshot.sourceApp)
                insert(entry: entry)
            } catch {
                displayAlert(message: "保存图片失败：\(error.localizedDescription)")
            }
        }
    }

    private func shouldIgnore(snapshot: ClipboardSnapshot) -> Bool {
        guard let fingerprint = fingerprint(for: snapshot) else { return false }
        let now = Date()
        purgeExpiredIgnoredPasteboardFingerprints(now: now)
        defer {
            lastCapturedFingerprint = fingerprint
            lastCaptureDate = now
        }
        if let ignoredDate = ignoredPasteboardFingerprints[fingerprint],
           now.timeIntervalSince(ignoredDate) <= ignoredPasteboardFingerprintTTL {
            ignoredPasteboardFingerprints.removeValue(forKey: fingerprint)
            return true
        }
        if let lastFingerprint = lastCapturedFingerprint,
           let lastDate = lastCaptureDate,
           lastFingerprint == fingerprint,
           now.timeIntervalSince(lastDate) < 0.6 {
            return true
        }
        return false
    }

    private enum PasteboardWriteContent {
        case text(String)
        case image(NSImage)
    }

    private func rememberInternalPasteboardWrite(_ content: PasteboardWriteContent) {
        let fingerprint: String?
        switch content {
        case .text(let string):
            fingerprint = hash(Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        case .image(let image):
            fingerprint = image.pngData().map { hash($0) }
        }
        if let fingerprint {
            ignoredPasteboardFingerprints[fingerprint] = Date()
        }
    }

    private func purgeExpiredIgnoredPasteboardFingerprints(now: Date) {
        ignoredPasteboardFingerprints = ignoredPasteboardFingerprints.filter { _, date in
            now.timeIntervalSince(date) <= ignoredPasteboardFingerprintTTL
        }
    }

    private func fingerprint(for snapshot: ClipboardSnapshot) -> String? {
        switch snapshot.type {
        case .text(let string):
            return hash(Data(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        case .image(let image):
            guard let data = image.pngData() else { return nil }
            return hash(data)
        }
    }

    private func hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func insert(entry: ClipboardEntry) {
        let enrichedEntry = applyingDerivedMetadata(to: entry)
        entries.insert(enrichedEntry, at: 0)
        if entries.count > settings.historyLimit {
            entries.removeLast(entries.count - settings.historyLimit)
        }
        store.append(entry: enrichedEntry)
        store.enforceQuota(historyLimit: settings.historyLimit, imageQuotaMB: settings.imageQuotaMB)
    }

    private func applyingDerivedMetadata(to entry: ClipboardEntry) -> ClipboardEntry {
        guard entry.type == .text, let text = entry.text else {
            var plainEntry = entry
            plainEntry.formattedTimestampText = nil
            plainEntry.isJSONText = false
            plainEntry.developerMetadata = nil
            return plainEntry
        }

        let metadata = ClipboardTextAnalyzer.analyze(text, settings: settings)
        var enrichedEntry = entry
        enrichedEntry.formattedTimestampText = metadata.formattedTimestampText
        enrichedEntry.isJSONText = metadata.isJSONText
        enrichedEntry.developerMetadata = metadata.developerMetadata
        return enrichedEntry
    }

    private func refreshDerivedMetadata() {
        entries = entries.map { applyingDerivedMetadata(to: $0) }
    }

    private func watcherCaptureFallback() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return ClipboardSnapshot(type: .text(string), sourceApp: "手动捕获")
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            return ClipboardSnapshot(type: .image(image), sourceApp: "手动捕获")
        }
        return nil
    }

    private func remove(entryID: UUID) {
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            let entry = entries.remove(at: index)
            if entry.type == .image, let name = entry.imagePath {
                Self.imageCache.removeObject(forKey: name as NSString)
                (store as? ClipboardHistoryStore)?.deleteImage(named: name)
            }
            store.removeEntry(id: entryID)
        }
    }

    private func displayAlert(message: String) {
        alertMessage = message
        showingAlert = true
    }

    private func performDeveloperAction(_ action: ClipboardDeveloperAction) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(action.fallbackText, forType: .string)
        rememberInternalPasteboardWrite(.text(action.fallbackText))
    }
}
