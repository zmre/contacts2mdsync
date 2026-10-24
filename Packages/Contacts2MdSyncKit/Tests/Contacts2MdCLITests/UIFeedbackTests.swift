import Contacts2MdCLI
import Foundation
import SyncEngine
import Testing

@Suite("Immediate feedback: banner actions, toolbar phases, pending switches")
struct UIFeedbackTests {
    @Test("a banner action shows its verb at once, then the run's phase with counts")
    func actionThenPhases() {
        var feedback = UIRunFeedback(.resumeAnyway)
        #expect(feedback.action.bannerID == "breaker")
        #expect(feedback.buttonTitle == "Resuming…")
        #expect(feedback.statusText == "Resuming…")
        feedback.phase = .readingContacts(cards: 3_781)
        #expect(feedback.statusText == "Reading Contacts (3,781 cards)…")
        #expect(feedback.buttonTitle == "Resuming…")
        feedback.phase = .scanningNotes(count: 2_447)
        #expect(feedback.statusText == "Scanning notes (2,447)…")
        feedback.phase = .readingContactNotes
        #expect(feedback.statusText == "Reading notes from Contacts…")
        feedback.phase = .planning
        #expect(feedback.statusText == "Planning…")
        feedback.phase = .writing
        #expect(feedback.statusText == "Writing…")
    }

    @Test("waiting behind another sync on this Mac says so (button and toolbar)")
    func waiting() {
        var feedback = UIRunFeedback(.applyAnyway, isWaiting: true)
        #expect(feedback.statusText == "Waiting for the current sync to finish…")
        #expect(feedback.buttonTitle == "Waiting…")
        feedback.isWaiting = false
        feedback.phase = .waitingForLock  // the local lock (the CLI or a launchd run)
        #expect(feedback.statusText == "Waiting for the current sync to finish…")
        feedback.phase = .planning
        #expect(feedback.buttonTitle == "Applying…")
    }

    @Test("every banner action maps to its banner and verb")
    func actions() {
        let expected: [UIUserAction: [String?]] = [
            .syncNow: [nil, "Syncing…"], .resumeAnyway: ["breaker", "Resuming…"],
            .applyAnyway: ["blast-radius", "Applying…"], .takeOver: ["lease", "Taking Over…"],
            .checkAgain: ["breaker", "Checking…"], .turnOnAppleWrites: ["apple-writes", "Turning On…"],
        ]
        for (action, values) in expected {
            #expect([action.bannerID, action.progressTitle] == values, "\(action)")
        }
        // The banner ids are the ones `UIBanner` uses.
        #expect(UIBanner.appleWritesDisabled(held: 1, kinds: "").id == "apple-writes")
        #expect(UIBanner.blastRadius(count: 30, limit: 25).id == "blast-radius")
        #expect(UIBanner.breaker(BreakerTrip(side: "apple", vanished: 1, total: 1)).id == "breaker")
    }

    @Test("a switch being saved shows its new position at once; stored afterwards")
    func pendingOptions() {
        let stored = UIVaultOptions(appleWrites: false, stampContacts: false)
        let requested = UIVaultOptions(appleWrites: true, stampContacts: false)
        #expect(UIPendingOptions.displayed(stored: stored, pending: UIPendingOptions(requested)) == requested)
        #expect(UIPendingOptions.displayed(stored: stored, pending: nil) == stored)
        #expect(UIPendingOptions.displayed(stored: nil, pending: nil) == nil)
    }

    @Test("counts in a confirmation say when they were computed")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = UICountFreshness(computedAt: now.addingTimeInterval(-60), isUpdating: true)
        #expect(fresh.asOf(now: now).hasPrefix("as of Today "))
        #expect(UICountFreshness(computedAt: nil, isUpdating: false).asOf(now: now).isEmpty)
    }

    @Test("phase timings: totals, re-plans add up, sub-phases taken out of their phase, verbose line")
    func timings() {
        var timings = PhaseTimings()
        timings.add("scan", seconds: 0.42)
        timings.add("contacts", seconds: 3.6)
        timings.add("plan", seconds: 1.0)
        timings.add("plan", seconds: 0.2)
        timings.split("contact-notes", seconds: 0.5, outOf: "contacts")
        timings.add("write", seconds: 2.0)
        timings.add("reread", seconds: 1.5)
        timings.exclude("reread", from: "write")
        timings.add("noise", seconds: 0.001)
        #expect(timings["plan"] == 1.2)
        #expect(abs(timings["contacts"] - 3.1) < 1e-9)
        #expect(
            timings.line == "scan 0.42s  contacts 3.10s  contact-notes 0.50s  plan 1.20s  write 0.50s  reread 1.50s")
        #expect(abs(timings.total - 7.221) < 1e-9)
        let timer = PhaseTimer()
        let value = timer.measure("work") { 42 }
        #expect(value == 42 && timer.timings.entries.map(\.phase) == ["work"])
    }
}
