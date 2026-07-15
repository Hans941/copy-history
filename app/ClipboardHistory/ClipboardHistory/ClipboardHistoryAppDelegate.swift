import AppKit

final class ClipboardHistoryAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !DEBUG
        guard validateLaunchLocation() else { return }
#endif
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "CopyCopy")
            button.image = image?.withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.toolTip = "CopyCopy"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示/隐藏面板", action: #selector(togglePanelFromStatusItem), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置", action: #selector(showSettingsFromStatusItem), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 CopyCopy", action: #selector(quitApplication), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    @objc func togglePanelFromStatusItem() {
        NotificationCenter.default.post(name: .togglePanelRequested, object: nil)
    }

    @objc func showSettingsFromStatusItem() {
        NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    @discardableResult
    private func validateLaunchLocation() -> Bool {
        guard let issue = LaunchEnvironmentValidator.issue(for: Bundle.main.bundleURL) else {
            return true
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "请先把 CopyCopy 移到“应用程序”文件夹"
        alert.informativeText = issue.informativeText
        alert.addButton(withTitle: "打开应用程序文件夹")
        alert.addButton(withTitle: "退出")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(LaunchEnvironmentValidator.localApplicationsDirectory)
        }

        NSApp.terminate(nil)
        return false
    }
}

enum LaunchLocationIssue: Equatable {
    case translocated
    case notInstalled

    var informativeText: String {
        switch self {
        case .translocated:
            return "当前 CopyCopy 正在 macOS 的临时隔离位置中运行。这种启动方式不稳定，系统可能回收底层文件映射，导致应用在后台崩溃。请先把 CopyCopy.app 拖到“应用程序”文件夹，再右键“打开”一次。"
        case .notInstalled:
            return "当前 CopyCopy 没有从“应用程序”文件夹启动。为了避免临时目录、下载目录或聊天工具沙盒带来的运行时崩溃，请先把 CopyCopy.app 拖到“应用程序”文件夹，再重新打开。"
        }
    }
}

enum LaunchEnvironmentValidator {
    static let localApplicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func issue(
        for bundleURL: URL,
        localApplicationsDirectory: URL = LaunchEnvironmentValidator.localApplicationsDirectory,
        userApplicationsDirectory: URL? = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
    ) -> LaunchLocationIssue? {
        let bundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

        if bundlePath.contains("/AppTranslocation/") || bundlePath.contains("/private/var/folders/") {
            return .translocated
        }

        if isInsideApplicationsDirectory(bundleURL, applicationsDirectory: localApplicationsDirectory) {
            return nil
        }

        if let userApplicationsDirectory,
           isInsideApplicationsDirectory(bundleURL, applicationsDirectory: userApplicationsDirectory) {
            return nil
        }

        return .notInstalled
    }

    private static func isInsideApplicationsDirectory(_ bundleURL: URL, applicationsDirectory: URL) -> Bool {
        let bundlePath = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let applicationsPath = applicationsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return bundlePath == applicationsPath || bundlePath.hasPrefix(applicationsPath + "/")
    }
}
