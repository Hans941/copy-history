import Foundation

struct ClipboardTextMetadata: Equatable {
    var formattedTimestampText: String?
    var isJSONText: Bool

    static let empty = ClipboardTextMetadata(formattedTimestampText: nil, isJSONText: false)
}

enum ClipboardTextAnalyzer {
    private static let formatterCache = NSCache<NSString, DateFormatter>()
    private static let secondTimestampRange = Int64(946684800)...Int64(2524608000)
    private static let millisecondTimestampRange = Int64(946684800000)...Int64(2524608000000)

    static func analyze(_ text: String, settings: ClipboardSettings) -> ClipboardTextMetadata {
        ClipboardTextMetadata(
            formattedTimestampText: formattedTimestamp(from: text, settings: settings),
            isJSONText: isJSONObjectText(text)
        )
    }

    static func prettyPrintedJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              JSONSerialization.isValidJSONObject(jsonObject),
              let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
              let prettyString = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return prettyString
    }

    private static func formattedTimestamp(from text: String, settings: ClipboardSettings) -> String? {
        guard let date = timestampDate(from: text) else { return nil }
        return formatter(for: settings).string(from: date)
    }

    private static func timestampDate(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy(\.isNumber),
              let value = Int64(trimmed) else {
            return nil
        }

        if secondTimestampRange.contains(value) {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }

        if millisecondTimestampRange.contains(value) {
            return Date(timeIntervalSince1970: TimeInterval(value) / 1000)
        }

        return nil
    }

    private static func isJSONObjectText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return JSONSerialization.isValidJSONObject(jsonObject)
    }

    private static func formatter(for settings: ClipboardSettings) -> DateFormatter {
        let format = settings.timestampDisplayFormat.isEmpty ? "yyyy/MM/dd HH:mm:ss" : settings.timestampDisplayFormat
        let timezoneIdentifier = settings.timestampTimeZoneIdentifier.isEmpty ? TimeZone.current.identifier : settings.timestampTimeZoneIdentifier
        let cacheKey = "\(format)|\(timezoneIdentifier)" as NSString

        if let cached = formatterCache.object(forKey: cacheKey) {
            return cached
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        formatterCache.setObject(formatter, forKey: cacheKey)
        return formatter
    }
}
