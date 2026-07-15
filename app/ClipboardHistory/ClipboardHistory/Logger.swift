import os.log

struct ClipLog {
    private static let subsystem = "com.clipboard.history"
    private static let general = OSLog(subsystem: subsystem, category: "general")

    static func info(_ message: String) {
        os_log("%{public}@", log: general, type: .info, message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: general, type: .error, message)
    }
}
