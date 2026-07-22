import Foundation

struct ClipboardSettings: Codable, Equatable {
    var historyLimit: Int = 5000
    var imageQuotaMB: Int = 1024
    var pruneIntervalHours: Int = 6
    var theme: String = "auto"
    var timestampDisplayFormat: String = "yyyy/MM/dd HH:mm:ss"
    var timestampTimeZoneIdentifier: String = TimeZone.current.identifier
    var siteInfoDataFilePath: String = ""

    private enum CodingKeys: String, CodingKey {
        case historyLimit
        case imageQuotaMB
        case pruneIntervalHours
        case theme
        case timestampDisplayFormat
        case timestampTimeZoneIdentifier
        case siteInfoDataFilePath
    }

    init() {}

    init(historyLimit: Int = 5000,
         imageQuotaMB: Int = 1024,
         pruneIntervalHours: Int = 6,
         theme: String = "auto",
         timestampDisplayFormat: String = "yyyy/MM/dd HH:mm:ss",
         timestampTimeZoneIdentifier: String = TimeZone.current.identifier,
         siteInfoDataFilePath: String = "") {
        self.historyLimit = historyLimit
        self.imageQuotaMB = imageQuotaMB
        self.pruneIntervalHours = pruneIntervalHours
        self.theme = theme
        self.timestampDisplayFormat = timestampDisplayFormat
        self.timestampTimeZoneIdentifier = timestampTimeZoneIdentifier
        self.siteInfoDataFilePath = siteInfoDataFilePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 5000
        imageQuotaMB = try container.decodeIfPresent(Int.self, forKey: .imageQuotaMB) ?? 1024
        pruneIntervalHours = try container.decodeIfPresent(Int.self, forKey: .pruneIntervalHours) ?? 6
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "auto"
        timestampDisplayFormat = try container.decodeIfPresent(String.self, forKey: .timestampDisplayFormat) ?? "yyyy/MM/dd HH:mm:ss"
        timestampTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timestampTimeZoneIdentifier) ?? TimeZone.current.identifier
        siteInfoDataFilePath = try container.decodeIfPresent(String.self, forKey: .siteInfoDataFilePath) ?? ""
    }
}

protocol SettingsManaging: AnyObject {
    var current: ClipboardSettings { get }
    var settingsPublisher: Published<ClipboardSettings>.Publisher { get }
    func update(_ transform: @escaping (inout ClipboardSettings) -> Void)
}

final class SettingsManager: ObservableObject, SettingsManaging {
    var settingsPublisher: Published<ClipboardSettings>.Publisher { $current }
    static let shared = SettingsManager()

    @Published private(set) var current: ClipboardSettings
    private let fileURL: URL
    private let queue = DispatchQueue(label: "clipboard-history-settings")

    init(fileURL: URL? = nil) {
        let baseURL: URL
        if let fileURL {
            baseURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            baseURL = support.appending(path: "ClipboardHistory", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        self.fileURL = baseURL.appending(path: "settings.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(ClipboardSettings.self, from: data) {
            current = decoded
        } else {
            current = ClipboardSettings()
            save()
        }
    }

    func update(_ transform: @escaping (inout ClipboardSettings) -> Void) {
        queue.async {
            var updated = self.current
            transform(&updated)
            guard updated != self.current else { return }
            DispatchQueue.main.async {
                self.current = updated
            }
            self.save(settings: updated)
        }
    }

    private func save(settings: ClipboardSettings? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let target = settings ?? current
        if let data = try? encoder.encode(target) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
