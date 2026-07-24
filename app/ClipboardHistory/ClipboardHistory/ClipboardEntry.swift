import Foundation

enum ClipboardEntryType: String, Codable {
    case text
    case image
}

enum ClipboardTab: String, Codable, Identifiable {
    case clipboardHistory = "clipboard_history"
    case useful
    case echo
    case favorite

    static var displayTabs: [ClipboardTab] { [.clipboardHistory, .favorite] }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clipboardHistory:
            return "剪贴板历史"
        case .useful:
            return "useful"
        case .echo:
            return "echo"
        case .favorite:
            return "收藏"
        }
    }

    var supportsEditing: Bool {
        switch self {
        case .favorite, .clipboardHistory, .useful, .echo:
            return true
        }
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable {
    static let searchableTextPrefixLimit = 20_000

    let id: UUID
    var timestamp: Date
    var type: ClipboardEntryType
    var text: String?
    var imagePath: String?
    var isFavorite: Bool
    var tab: ClipboardTab
    var note: String
    var sourceApp: String
    var formattedTimestampText: String?
    var isJSONText: Bool
    var developerMetadata: ClipboardDeveloperMetadata?

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case type
        case text
        case imagePath
        case isFavorite
        case tab
        case note
        case sourceApp
        case formattedTimestampText
        case isJSONText
        case developerMetadata
    }

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         type: ClipboardEntryType,
         text: String? = nil,
         imagePath: String? = nil,
         isFavorite: Bool = false,
         tab: ClipboardTab = .clipboardHistory,
         note: String = "",
         sourceApp: String = "未知",
         formattedTimestampText: String? = nil,
         isJSONText: Bool = false,
         developerMetadata: ClipboardDeveloperMetadata? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.text = text
        self.imagePath = imagePath
        self.isFavorite = isFavorite
        self.tab = tab
        self.note = note
        self.sourceApp = sourceApp
        self.formattedTimestampText = formattedTimestampText
        self.isJSONText = isJSONText
        self.developerMetadata = developerMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        type = try container.decode(ClipboardEntryType.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tab = try container.decodeIfPresent(ClipboardTab.self, forKey: .tab) ?? .clipboardHistory
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp) ?? "未知"
        formattedTimestampText = try container.decodeIfPresent(String.self, forKey: .formattedTimestampText)
        isJSONText = try container.decodeIfPresent(Bool.self, forKey: .isJSONText) ?? false
        developerMetadata = try container.decodeIfPresent(ClipboardDeveloperMetadata.self, forKey: .developerMetadata)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(imagePath, forKey: .imagePath)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(tab, forKey: .tab)
        try container.encode(note, forKey: .note)
        try container.encode(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(formattedTimestampText, forKey: .formattedTimestampText)
        try container.encode(isJSONText, forKey: .isJSONText)
        try container.encodeIfPresent(developerMetadata, forKey: .developerMetadata)
    }

    var previewText: String {
        switch type {
        case .text:
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description ?? "(空文本)"
        case .image:
            return note.isEmpty ? "图片" : note
        }
    }

    var searchIndexText: String {
        var values: [String] = []
        if let text { values.append(Self.searchablePrefix(from: text)) }
        if !note.isEmpty { values.append(note) }
        if let formattedTimestampText { values.append(formattedTimestampText) }
        if let developerMetadata { values.append(developerMetadata.searchableText) }
        return values.joined(separator: " ").lowercased()
    }

    private static func searchablePrefix(from text: String) -> String {
        guard text.count > searchableTextPrefixLimit else { return text }
        return String(text.prefix(searchableTextPrefixLimit))
    }
}
