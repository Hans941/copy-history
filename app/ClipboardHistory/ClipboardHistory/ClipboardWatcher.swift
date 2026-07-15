import AppKit

struct ClipboardSnapshot {
    enum SnapshotType {
        case text(String)
        case image(NSImage)
    }

    let type: SnapshotType
    let sourceApp: String
}

protocol ClipboardWatching: AnyObject {
    var onCapture: ((ClipboardSnapshot) -> Void)? { get set }
    func start()
    func stop()
}

final class ClipboardWatcher: ClipboardWatching {
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: Timer?
    var onCapture: ((ClipboardSnapshot) -> Void)?

    init() {
        changeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkPasteboard() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let snapshot = captureSnapshot() else { return }
        onCapture?(snapshot)
    }

    private func captureSnapshot() -> ClipboardSnapshot? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return ClipboardSnapshot(type: .text(string), sourceApp: pasteboard.sourceAppName)
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let image = NSImage(data: data) {
            return ClipboardSnapshot(type: .image(image), sourceApp: pasteboard.sourceAppName)
        }
        return nil
    }
}

private extension NSPasteboard {
    var sourceAppName: String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
    }
}
