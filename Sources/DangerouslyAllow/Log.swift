import Foundation

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func emit(_ level: String, _ msg: String) {
        print("[\(formatter.string(from: Date()))] \(level) \(msg)")
        fflush(stdout)
    }

    static func info(_ msg: String) { emit("·", msg) }
    static func warn(_ msg: String) { emit("!", msg) }
    static func error(_ msg: String) { emit("✗", msg) }
    static func plain(_ msg: String) {
        print(msg)
        fflush(stdout)
    }
}
