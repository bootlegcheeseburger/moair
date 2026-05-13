import Foundation

enum FakeMode {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["MOAIR_FAKE"] == "1" { return true }
        if CommandLine.arguments.contains("--fake") { return true }
        return false
    }()
}
