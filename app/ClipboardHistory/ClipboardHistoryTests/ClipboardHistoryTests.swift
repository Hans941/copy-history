import XCTest
import AppKit
import Combine
@testable import CopyCopy

final class ClipboardHistoryTests: XCTestCase {
    func testInsertTextEntry() async throws {
        let store = InMemoryStore()
        let watcher = MockWatcher()
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher)
        }
        watcher.triggerText("hello")
        try await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run {
            XCTAssertEqual(viewModel.entries.first?.text, "hello")
        }
    }

    func testSearchRespectsSelectedTab() async throws {
        let regular = ClipboardEntry(type: .text, text: "hello world", isFavorite: false, sourceApp: "test")
        let favorite = ClipboardEntry(type: .text, text: "hello favorite", isFavorite: true, sourceApp: "test")
        let store = InMemoryStore(entries: [favorite, regular])
        let watcher = MockWatcher()
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            viewModel.selectedTab = .favorite
            viewModel.searchText = "hello"

            XCTAssertEqual(viewModel.filteredEntries.count, 1)
            XCTAssertEqual(viewModel.filteredEntries.first?.id, favorite.id)
        }
    }

    func testUpdateHistoryLimitAppliesImmediately() async throws {
        let entries = [
            ClipboardEntry(type: .text, text: "1", sourceApp: "test"),
            ClipboardEntry(type: .text, text: "2", sourceApp: "test"),
            ClipboardEntry(type: .text, text: "3", sourceApp: "test")
        ]
        let store = InMemoryStore(entries: entries)
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(historyLimit: 5000,
                                                                            imageQuotaMB: 1024,
                                                                            pruneIntervalHours: 6,
                                                                            theme: "auto"))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            viewModel.updateHistoryLimit(1)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.count, 1)
        }
        XCTAssertEqual(store.lastEnforcedHistoryLimit, 1)
    }

    func testInsertRespectsConfiguredHistoryLimit() async throws {
        let store = InMemoryStore()
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(historyLimit: 1,
                                                                            imageQuotaMB: 1024,
                                                                            pruneIntervalHours: 6,
                                                                            theme: "auto"))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        watcher.triggerText("first")
        watcher.triggerText("second")

        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.count, 1)
            XCTAssertEqual(viewModel.entries.first?.text, "second")
        }
        XCTAssertEqual(store.entries.count, 1)
    }

    func testImageQuotaTrimRemovesEntryAndFileTogether() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(baseDirectory: tempDirectory)
        let image = makeTestImage()
        let imageName = try store.persistImage(image)
        let imageURL = store.imageURL(for: imageName)

        store.append(entry: ClipboardEntry(type: .image,
                                           imagePath: imageName,
                                           isFavorite: false,
                                           sourceApp: "test"))

        store.enforceQuota(historyLimit: 10, imageQuotaMB: 0)

        XCTAssertTrue(store.loadEntries(limit: 10, offset: 0).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testCopyToPasteboardDoesNotRecaptureSameText() async throws {
        let original = ClipboardEntry(type: .text, text: "copy without recapture", sourceApp: "test")
        let store = InMemoryStore(entries: [original])
        let watcher = MockWatcher()
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            viewModel.copyToPasteboard(entry: original, showAlert: false)
        }
        watcher.triggerText("copy without recapture")

        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.filter { $0.text == "copy without recapture" }.count, 1)
        }
        XCTAssertEqual(store.entries.filter { $0.text == "copy without recapture" }.count, 1)
    }

    func testClearNonFavoritesRemovesImageFiles() throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardHistoryStore(baseDirectory: tempDirectory)
        let imageName = try store.persistImage(makeTestImage())
        let imageURL = store.imageURL(for: imageName)

        store.append(entry: ClipboardEntry(type: .image,
                                           imagePath: imageName,
                                           isFavorite: false,
                                           sourceApp: "test"))
        waitUntil(timeout: 1) {
            store.loadEntries(limit: 10, offset: 0).count == 1
        }

        store.clearNonFavorites()

        waitUntil(timeout: 1) {
            store.loadEntries(limit: 10, offset: 0).isEmpty &&
            !FileManager.default.fileExists(atPath: imageURL.path)
        }
        XCTAssertTrue(store.loadEntries(limit: 10, offset: 0).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testTimestampTextGeneratesFormattedPreview() async throws {
        let store = InMemoryStore()
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(
            historyLimit: 5000,
            imageQuotaMB: 1024,
            pruneIntervalHours: 6,
            theme: "auto",
            timestampDisplayFormat: "yyyy/MM/dd HH:mm:ss",
            timestampTimeZoneIdentifier: "Asia/Shanghai"
        ))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        watcher.triggerText("1704067200")
        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.first?.formattedTimestampText, "2024/01/01 08:00:00")
        }
    }

    func testTimestampOutsideAllowedRangeDoesNotGeneratePreview() async throws {
        let store = InMemoryStore()
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(
            historyLimit: 5000,
            imageQuotaMB: 1024,
            pruneIntervalHours: 6,
            theme: "auto",
            timestampDisplayFormat: "yyyy/MM/dd HH:mm:ss",
            timestampTimeZoneIdentifier: "Asia/Shanghai"
        ))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        watcher.triggerText("2524608001")
        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            XCTAssertNil(viewModel.entries.first?.formattedTimestampText)
        }
    }

    func testTimestampPreviewRefreshesWhenSettingsChange() async throws {
        let entry = ClipboardEntry(type: .text, text: "1704067200", sourceApp: "test")
        let store = InMemoryStore(entries: [entry])
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(
            historyLimit: 5000,
            imageQuotaMB: 1024,
            pruneIntervalHours: 6,
            theme: "auto",
            timestampDisplayFormat: "yyyy/MM/dd HH:mm:ss",
            timestampTimeZoneIdentifier: "Asia/Shanghai"
        ))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.first?.formattedTimestampText, "2024/01/01 08:00:00")
            viewModel.updateTimestampTimeZoneIdentifier("UTC")
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.first?.formattedTimestampText, "2024/01/01 00:00:00")
        }
    }

    func testJSONObjectEnablesPrettyPreview() async throws {
        let entry = ClipboardEntry(type: .text,
                                   text: "{\"b\":1,\"a\":[2,3]}",
                                   sourceApp: "test")
        let store = InMemoryStore(entries: [entry])
        let watcher = MockWatcher()
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            XCTAssertEqual(viewModel.entries.first?.isJSONText, true)
            let preview = viewModel.jsonPreview(for: viewModel.entries[0])
            XCTAssertTrue(preview?.contains("\"a\"") == true)
            XCTAssertTrue(preview?.contains("\"b\"") == true)
        }
    }

    func testDeveloperMetadataFormatsConfiguredSiteInfo() async throws {
        let siteInfoURL = try makeSiteInfoCatalogFile()
        let store = InMemoryStore()
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(siteInfoDataFilePath: siteInfoURL.path))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        watcher.triggerText("""
        app_local=es site_id=10042
        https://sgp-op.api.mi.com/site-info?app_local=fr
        """)
        try await Task.sleep(nanoseconds: 200_000_000)

        await MainActor.run {
            let metadata = viewModel.entries.first?.developerMetadata
            XCTAssertEqual(metadata?.appLocals, ["es", "fr"])
            XCTAssertEqual(metadata?.siteIdentifiers.first, "10042")
            XCTAssertEqual(metadata?.domains.first, "sgp-op.api.mi.com")
            XCTAssertEqual(metadata?.siteInfos.first?.siteName, "西班牙")
            XCTAssertEqual(metadata?.siteInfos.first?.shopType, "B2C")
            XCTAssertEqual(metadata?.siteInfos.first?.idc, "sg")
            XCTAssertTrue(metadata?.summaryText.contains("西班牙") == true)
            XCTAssertTrue(metadata?.summaryText.contains("出口 sg") == true)
        }
    }

    func testDeveloperMetadataDetectsBareAppLocalWhenCatalogKnowsIt() async throws {
        let siteInfoURL = try makeSiteInfoCatalogFile()
        let metadata = ClipboardTextAnalyzer.analyze(
            "es",
            settings: ClipboardSettings(siteInfoDataFilePath: siteInfoURL.path)
        ).developerMetadata

        XCTAssertEqual(metadata?.appLocals, ["es"])
        XCTAssertEqual(metadata?.siteInfos.first?.siteID, "10042")
        XCTAssertEqual(metadata?.summaryText, "es · site 10042 · 西班牙 · B2C · 出口 sg · XIAOMI")
    }

    func testDeveloperMetadataDetectsBareSiteIDWhenCatalogKnowsIt() async throws {
        let siteInfoURL = try makeSiteInfoCatalogFile()
        let metadata = ClipboardTextAnalyzer.analyze(
            "10042",
            settings: ClipboardSettings(siteInfoDataFilePath: siteInfoURL.path)
        ).developerMetadata

        XCTAssertEqual(metadata?.siteIdentifiers, ["10042"])
        XCTAssertEqual(metadata?.siteInfos.first?.appLocal, "es")
        XCTAssertEqual(metadata?.summaryText, "es · site 10042 · 西班牙 · B2C · 出口 sg · XIAOMI")
    }

    func testDeveloperMetadataHandlesDuplicateAppLocalsInCatalog() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let json = """
        [
          {"app_local":"es","site_id":"1","site_name":"Poco España","shop_type":"B2C","tenant_id":"POCO","site_type":"shop"},
          {"app_local":"es","site_id":"2","site_name":"Xiaomi España","shop_type":"B2C","tenant_id":"XIAOMI","idc":"ams","site_type":"shop"}
        ]
        """
        try Data(json.utf8).write(to: url)

        let metadata = ClipboardTextAnalyzer.analyze(
            "es",
            settings: ClipboardSettings(siteInfoDataFilePath: url.path)
        ).developerMetadata

        XCTAssertEqual(metadata?.siteInfos.first?.siteID, "2")
        XCTAssertEqual(metadata?.siteInfos.first?.tenantID, "XIAOMI")
    }

    func testDeveloperMetadataSearchMatchesDerivedValues() async throws {
        let siteInfoURL = try makeSiteInfoCatalogFile()
        let entry = ClipboardEntry(type: .text,
                                   text: "app_local=es",
                                   sourceApp: "test")
        let store = InMemoryStore(entries: [entry])
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(siteInfoDataFilePath: siteInfoURL.path))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            viewModel.searchText = "西班牙"
            XCTAssertEqual(viewModel.filteredEntries.count, 1)
        }
    }

    func testDeveloperSiteInfoActionCopiesFormattedInfo() {
        let metadata = ClipboardDeveloperMetadata(appLocals: ["es"],
                                                  siteIdentifiers: ["10042"],
                                                  domains: [],
                                                  urls: [],
                                                  siteInfos: [ClipboardSiteInfo(appLocal: "es",
                                                                                siteID: "10042",
                                                                                siteName: "西班牙",
                                                                                shopType: "B2C",
                                                                                idc: "sg",
                                                                                tenantID: "XIAOMI",
                                                                                areaID: "ES")])

        let action = ClipboardDeveloperActionBuilder.siteInfoAction(metadata: metadata)

        XCTAssertEqual(action?.fallbackText, "es · site 10042 · 西班牙 · B2C · 出口 sg · XIAOMI")
    }

    func testCopySiteInfoActionDoesNotShowAlert() async throws {
        let siteInfoURL = try makeSiteInfoCatalogFile()
        let entry = ClipboardEntry(type: .text,
                                   text: "app_local=es",
                                   sourceApp: "test")
        let store = InMemoryStore(entries: [entry])
        let watcher = MockWatcher()
        let settingsManager = MockSettingsManager(current: ClipboardSettings(siteInfoDataFilePath: siteInfoURL.path))
        let viewModel = await MainActor.run {
            ClipboardHistoryViewModel(store: store, watcher: watcher, settingsManager: settingsManager)
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        await MainActor.run {
            viewModel.openSiteInfoAction(for: viewModel.entries[0])
            XCTAssertFalse(viewModel.showingAlert)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "es · site 10042 · 西班牙 · B2C · 出口 sg · XIAOMI")
        }
    }

    func testClipboardEntryCodableKeepsDeveloperMetadataOptional() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "timestamp": 1704067200,
          "type": "text",
          "text": "hello",
          "isFavorite": false,
          "tab": "clipboard_history",
          "note": "",
          "sourceApp": "test",
          "isJSONText": false
        }
        """

        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(decoded.developerMetadata)

        let current = ClipboardEntry(type: .text,
                                     text: "app_local=es",
                                     sourceApp: "test",
                                     developerMetadata: ClipboardDeveloperMetadata(appLocals: ["es"],
                                                                                  siteIdentifiers: [],
                                                                                  domains: [],
                                                                                  urls: [],
                                                                                  siteInfos: []))
        let encoded = try JSONEncoder().encode(current)
        let roundTrip = try JSONDecoder().decode(ClipboardEntry.self, from: encoded)

        XCTAssertEqual(roundTrip.developerMetadata?.appLocals, ["es"])
        XCTAssertEqual(roundTrip.developerMetadata?.siteIdentifiers, [])
    }

    func testJSONPreviewSearchMatchesKeywordCaseInsensitively() {
        let ranges = JSONPreviewSearch.matchRanges(
            in: "{\n  \"Name\": \"Alice\",\n  \"nickname\": \"ALICE\"\n}",
            keyword: "alice"
        )

        XCTAssertEqual(ranges.count, 2)
    }

    func testLaunchEnvironmentValidatorAllowsApplicationsDirectory() {
        let bundleURL = URL(fileURLWithPath: "/Applications/CopyCopy.app", isDirectory: true)

        XCTAssertNil(
            LaunchEnvironmentValidator.issue(
                for: bundleURL,
                localApplicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplicationsDirectory: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
            )
        )
    }

    func testLaunchEnvironmentValidatorAllowsUserApplicationsDirectory() {
        let bundleURL = URL(fileURLWithPath: "/Users/test/Applications/CopyCopy.app", isDirectory: true)

        XCTAssertNil(
            LaunchEnvironmentValidator.issue(
                for: bundleURL,
                localApplicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplicationsDirectory: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
            )
        )
    }

    func testLaunchEnvironmentValidatorRejectsTranslocatedPath() {
        let bundleURL = URL(fileURLWithPath: "/private/var/folders/ab/cd/AppTranslocation/XYZ/d/CopyCopy.app", isDirectory: true)

        XCTAssertEqual(
            LaunchEnvironmentValidator.issue(
                for: bundleURL,
                localApplicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplicationsDirectory: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
            ),
            .translocated
        )
    }

    func testLaunchEnvironmentValidatorRejectsNonApplicationsPath() {
        let bundleURL = URL(fileURLWithPath: "/Users/test/Downloads/CopyCopy.app", isDirectory: true)

        XCTAssertEqual(
            LaunchEnvironmentValidator.issue(
                for: bundleURL,
                localApplicationsDirectory: URL(fileURLWithPath: "/Applications", isDirectory: true),
                userApplicationsDirectory: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true)
            ),
            .notInstalled
        )
    }

    func testPanelWindowManagerDefaultCollectionBehaviorSupportsFullscreenSpaces() {
        let behavior = PanelWindowManager.defaultCollectionBehavior

        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.stationary))
    }

    @MainActor
    func testJSONPreviewWindowContainsScreenPointInsideWindow() {
        let manager = JSONPreviewWindowManager.shared
        manager.show(payload: JSONPreviewPayload(title: "test", content: "{\n  \"a\": 1\n}"))
        defer { manager.close() }

        guard let window = manager.currentWindow else {
            XCTFail("JSON 预览窗口未创建")
            return
        }

        let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
        XCTAssertTrue(manager.containsScreenPoint(point))
    }

    @MainActor
    func testStatusItemTogglePostsNotification() {
        let appDelegate = ClipboardHistoryAppDelegate()
        let expectation = expectation(forNotification: .togglePanelRequested, object: nil)

        appDelegate.togglePanelFromStatusItem()

        wait(for: [expectation], timeout: 1)
    }

    @MainActor
    func testStatusItemSettingsPostsNotification() {
        let appDelegate = ClipboardHistoryAppDelegate()
        let expectation = expectation(forNotification: .showSettingsRequested, object: nil)

        appDelegate.showSettingsFromStatusItem()

        wait(for: [expectation], timeout: 1)
    }

    private func makeTestImage() -> NSImage {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    private func makeSiteInfoCatalogFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let json = """
        [
          {
            "app_local": "es",
            "site_id": "10042",
            "site_name": "西班牙",
            "shop_type": "B2C",
            "idc": "sg",
            "tenant_id": "XIAOMI",
            "area_id": "ES"
          },
          {
            "app_local": "fr",
            "site_id": "10043",
            "site_name": "法国",
            "shop_type": "B2C",
            "idc": "ams",
            "tenant_id": "XIAOMI",
            "area_id": "FR"
          }
        ]
        """
        try Data(json.utf8).write(to: url)
        return url
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

final class MockWatcher: ClipboardWatching {
    var onCapture: ((ClipboardSnapshot) -> Void)?
    func start() {}
    func stop() {}

    func triggerText(_ text: String) {
        let snapshot = ClipboardSnapshot(type: .text(text), sourceApp: "test")
        onCapture?(snapshot)
    }
}

final class InMemoryStore: ClipboardHistoryPersisting {
    private(set) var entries: [ClipboardEntry]
    private(set) var lastEnforcedHistoryLimit: Int?

    init(entries: [ClipboardEntry] = []) {
        self.entries = entries
    }

    func loadEntries(limit: Int?, offset: Int) -> [ClipboardEntry] { entries }
    func searchEntries(keyword: String, limit: Int) -> [ClipboardEntry] { entries.filter { $0.text?.contains(keyword) == true } }
    func saveEntries(_ entries: [ClipboardEntry]) { self.entries = entries }
    func append(entry: ClipboardEntry) { entries.insert(entry, at: 0) }
    func updateEntry(_ entry: ClipboardEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        }
    }
    func removeEntry(id: UUID) { entries.removeAll { $0.id == id } }
    func clearNonFavorites() { entries.removeAll { !$0.isFavorite } }
    func enforceQuota(historyLimit: Int, imageQuotaMB: Int) {
        lastEnforcedHistoryLimit = historyLimit
        entries = Array(entries.prefix(historyLimit))
    }
    func persistImage(_ image: NSImage) throws -> String { "mock.png" }
    func deleteImage(named: String) {}
    func imageURL(for relativePath: String) -> URL { URL(fileURLWithPath: relativePath) }
}

final class MockSettingsManager: ObservableObject, SettingsManaging {
    var settingsPublisher: Published<ClipboardSettings>.Publisher { $current }

    @Published private(set) var current: ClipboardSettings

    init(current: ClipboardSettings) {
        self.current = current
    }

    func update(_ transform: @escaping (inout ClipboardSettings) -> Void) {
        transform(&current)
    }
}
