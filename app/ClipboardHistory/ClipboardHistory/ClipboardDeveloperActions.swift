import Foundation

struct ClipboardDeveloperAction: Equatable {
    var fallbackText: String
    var message: String
}

enum ClipboardDeveloperActionBuilder {
    static func siteInfoAction(metadata: ClipboardDeveloperMetadata) -> ClipboardDeveloperAction? {
        guard metadata.hasSiteContext else { return nil }
        let fallbackText = metadata.siteInfos.first?.displayText ?? metadata.summaryText
        guard !fallbackText.isEmpty else { return nil }
        return ClipboardDeveloperAction(
            fallbackText: fallbackText,
            message: "已复制 site 信息"
        )
    }
}
