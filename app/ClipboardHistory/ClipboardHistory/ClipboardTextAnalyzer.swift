import Foundation

struct ClipboardTextMetadata: Equatable {
    var formattedTimestampText: String?
    var isJSONText: Bool
    var developerMetadata: ClipboardDeveloperMetadata?

    static let empty = ClipboardTextMetadata(formattedTimestampText: nil, isJSONText: false, developerMetadata: nil)
}

struct ClipboardDeveloperMetadata: Codable, Equatable {
    var appLocals: [String]
    var siteIdentifiers: [String]
    var domains: [String]
    var urls: [String]
    var siteInfos: [ClipboardSiteInfo]

    var isEmpty: Bool {
        appLocals.isEmpty &&
        siteIdentifiers.isEmpty &&
        domains.isEmpty &&
        urls.isEmpty &&
        siteInfos.isEmpty
    }

    var primaryAppLocal: String? { appLocals.first }
    var primarySiteIdentifier: String? { siteIdentifiers.first }
    var primaryDomain: String? { domains.first }
    var primaryURL: String? { urls.first }

    var hasSiteContext: Bool {
        primaryAppLocal != nil || primarySiteIdentifier != nil || primaryDomain != nil || primaryURL != nil || !siteInfos.isEmpty
    }

    var searchableText: String {
        var values = [summaryText]
        values.append(contentsOf: appLocals)
        values.append(contentsOf: siteIdentifiers)
        values.append(contentsOf: domains)
        values.append(contentsOf: urls)
        siteInfos.forEach { values.append($0.searchableText) }
        return values.joined(separator: " ")
    }

    var summaryText: String {
        if let siteInfo = siteInfos.first {
            return siteInfo.displayText
        }

        var parts: [String] = []
        if let primaryAppLocal {
            parts.append(primaryAppLocal)
        }
        if let primarySiteIdentifier {
            parts.append("site \(primarySiteIdentifier)")
        }
        if let primaryDomain {
            parts.append(primaryDomain)
        } else if let primaryURL,
                  let host = URLComponents(string: primaryURL)?.host {
            parts.append(host)
        }
        return parts.joined(separator: " · ")
    }
}

struct ClipboardSiteInfo: Codable, Equatable {
    var appLocal: String
    var siteID: String?
    var siteName: String?
    var shopType: String?
    var idc: String?
    var tenantID: String?
    var areaID: String?
    var siteType: String?

    private enum CodingKeys: String, CodingKey {
        case appLocal = "app_local"
        case siteID = "site_id"
        case siteName = "site_name"
        case shopType = "shop_type"
        case idc
        case tenantID = "tenant_id"
        case areaID = "area_id"
        case siteType = "site_type"
    }

    var displayText: String {
        var parts = [appLocal]
        if let siteID, !siteID.isEmpty { parts.append("site \(siteID)") }
        if let siteName, !siteName.isEmpty { parts.append(siteName) }
        if let shopType, !shopType.isEmpty { parts.append(shopType) }
        if let idc, !idc.isEmpty { parts.append("出口 \(idc)") }
        if let tenantID, !tenantID.isEmpty { parts.append(tenantID) }
        return parts.joined(separator: " · ")
    }

    var searchableText: String {
        [appLocal, siteID, siteName, shopType, idc, tenantID, areaID, siteType]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

enum ClipboardTextAnalyzer {
    private static let formatterCache = NSCache<NSString, DateFormatter>()
    private static let secondTimestampRange = Int64(946684800)...Int64(2524608000)
    private static let millisecondTimestampRange = Int64(946684800000)...Int64(2524608000000)
    private static let trailingURLPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'、，。；：！？）】」』")
    private static let miDomainSuffixes = ["mi.com", "xiaomi.com", "po.co"]

    static func analyze(_ text: String, settings: ClipboardSettings) -> ClipboardTextMetadata {
        ClipboardTextMetadata(
            formattedTimestampText: formattedTimestamp(from: text, settings: settings),
            isJSONText: isJSONObjectText(text),
            developerMetadata: developerMetadata(from: text, settings: settings)
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

    private static func developerMetadata(from text: String, settings: ClipboardSettings) -> ClipboardDeveloperMetadata? {
        let catalog = ClipboardSiteInfoCatalog.load(from: settings.siteInfoDataFilePath)
        let urls = extractURLs(from: text)
        let urlComponents = urls.compactMap(URLComponents.init(string:))
        let urlDomains = urlComponents.compactMap { $0.host?.lowercased() }.filter(isInternationalMiDomain)
        let textDomains = regexCaptures(in: text, pattern: #"\b((?:[A-Za-z0-9-]+\.)+(?:mi\.com|xiaomi\.com|po\.co))\b"#, group: 1)
            .map { $0.lowercased() }
            .filter(isInternationalMiDomain)
        let appLocals = normalizedAppLocals(from: text, components: urlComponents, catalog: catalog)
        let siteIdentifiers = normalizedSiteIdentifiers(from: text, components: urlComponents, catalog: catalog)
        let siteInfos = matchedSiteInfos(appLocals: appLocals, siteIdentifiers: siteIdentifiers, catalog: catalog)

        let metadata = ClipboardDeveloperMetadata(
            appLocals: unique(appLocals),
            siteIdentifiers: unique(siteIdentifiers),
            domains: unique(urlDomains + textDomains),
            urls: unique(urls.filter { url in
                guard let host = URLComponents(string: url)?.host else { return false }
                return isInternationalMiDomain(host)
            }),
            siteInfos: siteInfos
        )

        return metadata.isEmpty ? nil : metadata
    }

    private static func extractURLs(from text: String) -> [String] {
        regexCaptures(in: text, pattern: #"https?://[^\s<>\"']+"#, group: 0)
            .map { $0.trimmingCharacters(in: trailingURLPunctuation) }
    }

    private static func normalizedAppLocals(from text: String, components: [URLComponents], catalog: ClipboardSiteInfoCatalog) -> [String] {
        let labeled = regexCaptures(
            in: text,
            pattern: #"(?i)\b(app[_-]?local|appLocal|mi_app_local)\b\s*[:=]\s*[\"']?([A-Za-z]{2,5}(?:[_-][A-Za-z]{2})?)"#,
            group: 2
        )
        let queryItems = components.flatMap { component in
            queryValues(in: component, names: ["app_local", "appLocal", "mi_app_local"])
        }
        let bare = bareCatalogAppLocal(from: text, catalog: catalog)
        return (labeled + queryItems + bare).map { $0.replacingOccurrences(of: "-", with: "_").lowercased() }
    }

    private static func normalizedSiteIdentifiers(from text: String, components: [URLComponents], catalog: ClipboardSiteInfoCatalog) -> [String] {
        let labeled = regexCaptures(
            in: text,
            pattern: #"(?i)\b(site[_-]?id|siteId|mi_site_id|site)\b\s*[:=]\s*[\"']?([A-Za-z0-9][A-Za-z0-9_-]{1,63})"#,
            group: 2
        )
        let queryItems = components.flatMap { component in
            queryValues(in: component, names: ["site_id", "siteId", "mi_site_id", "site"])
        }
        let bare = bareCatalogSiteID(from: text, catalog: catalog)
        return labeled + queryItems + bare
    }

    private static func bareCatalogAppLocal(from text: String, catalog: ClipboardSiteInfoCatalog) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[a-z]{2,5}(?:_[a-z]{2})?$"#, options: .regularExpression) != nil,
              catalog.siteInfo(appLocal: trimmed) != nil else {
            return []
        }
        return [trimmed]
    }

    private static func bareCatalogSiteID(from text: String, catalog: ClipboardSiteInfoCatalog) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^\d{3,12}$"#, options: .regularExpression) != nil,
              catalog.siteInfo(siteID: trimmed) != nil else {
            return []
        }
        return [trimmed]
    }

    private static func matchedSiteInfos(appLocals: [String], siteIdentifiers: [String], catalog: ClipboardSiteInfoCatalog) -> [ClipboardSiteInfo] {
        uniqueSiteInfos(
            unique(appLocals).compactMap { catalog.siteInfo(appLocal: $0) } +
            unique(siteIdentifiers).compactMap { catalog.siteInfo(siteID: $0) }
        )
    }

    private static func queryValues(in component: URLComponents, names: Set<String>) -> [String] {
        component.queryItems?.compactMap { item in
            names.contains(item.name) ? item.value : nil
        } ?? []
    }

    private static func regexCaptures(in text: String, pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group,
                  let captureRange = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[captureRange]).trimmingCharacters(in: trailingURLPunctuation)
        }
    }

    private static func isInternationalMiDomain(_ domain: String) -> Bool {
        let host = domain.lowercased()
        return miDomainSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(normalized)
        }
        return result
    }

    private static func uniqueSiteInfos(_ siteInfos: [ClipboardSiteInfo]) -> [ClipboardSiteInfo] {
        var seen: Set<String> = []
        var result: [ClipboardSiteInfo] = []
        for siteInfo in siteInfos {
            let key = siteInfo.siteID ?? siteInfo.appLocal.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(siteInfo)
        }
        return result
    }
}

final class ClipboardSiteInfoCatalog {
    private static var cache: [String: ClipboardSiteInfoCatalog] = [:]

    private let byAppLocal: [String: ClipboardSiteInfo]
    private let bySiteID: [String: ClipboardSiteInfo]

    private init(siteInfos: [ClipboardSiteInfo]) {
        var appLocalMap: [String: ClipboardSiteInfo] = [:]
        var siteIDMap: [String: ClipboardSiteInfo] = [:]
        for siteInfo in siteInfos {
            let appLocalKey = siteInfo.appLocal.lowercased()
            if let existing = appLocalMap[appLocalKey] {
                appLocalMap[appLocalKey] = Self.preferredSiteInfo(existing, siteInfo)
            } else {
                appLocalMap[appLocalKey] = siteInfo
            }
            if let siteID = siteInfo.siteID, !siteID.isEmpty {
                siteIDMap[siteID] = siteInfo
            }
        }
        byAppLocal = appLocalMap
        bySiteID = siteIDMap
    }

    static func load(from path: String) -> ClipboardSiteInfoCatalog {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return ClipboardSiteInfoCatalog(siteInfos: []) }
        if let cached = cache[normalizedPath] { return cached }

        let url = URL(fileURLWithPath: normalizedPath)
        let siteInfos = (try? Data(contentsOf: url)).flatMap { data in
            try? JSONDecoder().decode([ClipboardSiteInfo].self, from: data)
        } ?? []
        let catalog = ClipboardSiteInfoCatalog(siteInfos: siteInfos)
        cache[normalizedPath] = catalog
        return catalog
    }

    func siteInfo(appLocal: String) -> ClipboardSiteInfo? {
        byAppLocal[appLocal.lowercased()]
    }

    func siteInfo(siteID: String) -> ClipboardSiteInfo? {
        bySiteID[siteID]
    }

    private static func preferredSiteInfo(_ left: ClipboardSiteInfo, _ right: ClipboardSiteInfo) -> ClipboardSiteInfo {
        if score(right) > score(left) { return right }
        return left
    }

    private static func score(_ siteInfo: ClipboardSiteInfo) -> Int {
        var value = 0
        if siteInfo.tenantID == "XIAOMI" { value += 100 }
        if siteInfo.shopType == "B2C" { value += 50 }
        if siteInfo.siteType == "shop" { value += 20 }
        if siteInfo.idc?.isEmpty == false { value += 10 }
        return value
    }
}
