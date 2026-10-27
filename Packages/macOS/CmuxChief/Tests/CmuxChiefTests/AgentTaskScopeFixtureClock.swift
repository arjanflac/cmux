import Foundation

/// A manually advanced authority clock; no test waits on wall time.
actor AgentTaskScopeFixtureClock {
    private var instant = Date(timeIntervalSince1970: 1_000)

    func now() -> Date { instant }

    func advance(_ interval: TimeInterval) {
        instant.addTimeInterval(interval)
    }
}
