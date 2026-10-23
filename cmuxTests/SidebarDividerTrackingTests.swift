import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct SidebarDividerTrackingTests {
    @Test("a lost release ends tracking after a bounded idle wait")
    func lostRelease() {
        var polls = 0
        let result = SidebarDividerTrackingView.nextTrackingEvent(
            isTrackingActive: { false },
            nextEvent: { deadline in
                #expect(deadline < Date(timeIntervalSinceNow: 1))
                polls += 1
                return nil
            }
        )
        #expect(result == nil)
        #expect(polls == 1)
    }

    @Test("a queued release is delivered even after the physical button is up")
    func queuedRelease() throws {
        let event = try releaseEvent()
        let result = SidebarDividerTrackingView.nextTrackingEvent(
            isTrackingActive: { false }, nextEvent: { _ in event })
        #expect(result === event)
    }

    @Test("an idle interval does not cancel a drag while tracking remains active")
    func idleWhileHeld() throws {
        let event = try releaseEvent()
        var polls = 0
        let result = SidebarDividerTrackingView.nextTrackingEvent(
            isTrackingActive: { true }, nextEvent: { _ in
                polls += 1
                return polls == 2 ? event : nil
            })
        #expect(result === event)
        #expect(polls == 2)
    }

    private func releaseEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }
}
