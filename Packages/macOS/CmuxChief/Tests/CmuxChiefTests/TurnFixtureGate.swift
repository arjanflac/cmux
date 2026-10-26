import Foundation

actor TurnFixtureGate {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { releases.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func open() {
        released = true
        for release in releases { release.resume() }
        releases.removeAll()
    }
}
