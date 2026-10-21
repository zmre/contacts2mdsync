import AppKit
import CoreServices
import Foundation

/// Apple Events access to Contacts.app (spike S12). One compiled NSAppleScript
/// holds a few handlers; Swift calls them with a subroutine Apple Event, so
/// arguments travel as descriptors and are never spliced into script source.
///
/// Must be used from the main thread (NSAppleScript is not thread-safe); the
/// argument-parser commands run there.
final class ContactsScripting {
    static let bundleID = "com.apple.AddressBook"

    /// Handler names are lowercase: AppleScript folds handler identifiers to
    /// lowercase, and the subroutine event matches them by that name.
    private static let source = """
        on personcount()
        \ttell application id "com.apple.AddressBook" to return count of every person
        end personcount

        on allids()
        \ttell application id "com.apple.AddressBook" to return id of every person
        end allids

        on allnotes()
        \ttell application id "com.apple.AddressBook" to return note of every person
        end allnotes

        on noteof(pid)
        \ttell application id "com.apple.AddressBook" to return note of person id pid
        end noteof

        on identityof(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\treturn {id of p, first name of p, last name of p, value of every url of p}
        \tend tell
        end identityof

        on idsnamed(fn, ln)
        \ttell application id "com.apple.AddressBook"
        \t\treturn id of every person whose first name is fn and last name is ln
        \tend tell
        end idsnamed

        on setnote(pid, txt)
        \ttell application id "com.apple.AddressBook"
        \t\tset note of person id pid to txt
        \t\tsave
        \tend tell
        \treturn true
        end setnote
        """

    /// What `identityof` returns for one AppleScript person.
    struct Identity {
        var id: String
        var firstName: String
        var lastName: String
        var urls: [String]

        var displayName: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }

        /// Same two checks as `Harness.isHarness`, on the AppleScript view.
        var looksLikeHarness: Bool {
            displayName.hasPrefix(Harness.namePrefix) && urls.contains { Harness.markerSchemePrefix($0) != nil }
        }
    }

    /// An AppleScript/Apple Event failure with the OSA error number.
    struct ScriptError: Error, CustomStringConvertible, CustomNSError {
        var number: Int
        var message: String

        var description: String { "AppleScript error \(number): \(message)" }

        static var errorDomain: String { "AppleScript" }
        var errorCode: Int { number }
        var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }

        /// -1743 errAEEventNotPermitted: the user (or policy) denied Automation.
        var isPermissionDenied: Bool { number == -1743 }
        /// -1728 errAENoSuchObject: e.g. `person id X` does not resolve.
        var isNoSuchObject: Bool { number == -1728 }
    }

    private let script: NSAppleScript

    init() throws {
        guard let script = NSAppleScript(source: Self.source) else {
            throw SpikeError("NSAppleScript init failed")
        }
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            throw Self.scriptError(errorInfo)
        }
        self.script = script
    }

    // MARK: - Handlers

    func personCount() throws -> Int {
        Int(try call("personcount").int32Value)
    }

    func allIDs() throws -> [String] {
        try Self.strings(call("allids"))
    }

    /// One entry per person, in the same order as `allIDs()` when nothing
    /// changes in between; nil for `missing value`.
    func allNotes() throws -> [String?] {
        try Self.optionalStrings(call("allnotes"))
    }

    func note(of personID: String) throws -> String? {
        Self.optionalString(try call("noteof", .init(string: personID)))
    }

    func identity(of personID: String) throws -> Identity {
        let list = try call("identityof", .init(string: personID))
        guard list.numberOfItems == 4 else { throw SpikeError("identityof returned \(list.numberOfItems) items") }
        return Identity(
            id: Self.optionalString(list.atIndex(1)) ?? "",
            firstName: Self.optionalString(list.atIndex(2)) ?? "",
            lastName: Self.optionalString(list.atIndex(3)) ?? "",
            urls: Self.optionalStrings(list.atIndex(4)).compactMap { $0 })
    }

    func ids(firstName: String, lastName: String) throws -> [String] {
        try Self.strings(call("idsnamed", .init(string: firstName), .init(string: lastName)))
    }

    /// `set note of person id X to txt` followed by `save`. Callers must have
    /// verified the target is a harness person immediately before calling.
    func setNote(of personID: String, to text: String) throws {
        _ = try call("setnote", .init(string: personID), .init(string: text))
    }

    // MARK: - Process / permission state

    static var isContactsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    /// Terminates Contacts.app (used only when this run launched it).
    static func quitContacts() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }

    /// Automation permission for Contacts without prompting.
    /// noErr = granted, -1743 = denied, -1744 = would prompt, -600 = Contacts not running.
    static func automationStatus() -> (code: OSStatus, meaning: String) {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return (OSStatus(-50), "could not build target descriptor") }
        let wildcard = fourCC("****")
        let status = AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, false)
        let meaning: String
        switch status {
        case 0: meaning = "granted"
        case -1743: meaning = "DENIED (errAEEventNotPermitted)"
        case -1744: meaning = "not yet decided; the first Apple Event will prompt (errAEEventWouldRequireUserConsent)"
        case -600: meaning = "unknown: Contacts.app not running (procNotFound)"
        default: meaning = "OSStatus \(status)"
        }
        return (status, meaning)
    }

    static let permissionHelp = """
        Automation permission denied (-1743). macOS asks "<your terminal> wants to control Contacts" on the
        first Apple Event; it was refused or the decision is stored as "no".
          1. System Settings > Privacy & Security > Automation > <your terminal app> > enable "Contacts".
          2. Or reset and re-prompt:  tccutil reset AppleEvents   (resets Automation for ALL apps)
          3. Re-run the command from the same terminal app.
        """

    // MARK: - Plumbing

    private func call(_ handler: String, _ args: NSAppleEventDescriptor...) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: Self.fourCC("ascr"),  // kASAppleScriptSuite
            eventID: Self.fourCC("psbr"),  // kASSubroutineEvent
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(-1),  // kAutoGenerateReturnID
            transactionID: AETransactionID(0))  // kAnyTransactionID
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: Self.fourCC("snam"))
        let list = NSAppleEventDescriptor.list()
        for (index, arg) in args.enumerated() { list.insert(arg, at: index + 1) }
        event.setParam(list, forKeyword: Self.fourCC("----"))  // keyDirectObject
        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo { throw Self.scriptError(errorInfo) }
        return result
    }

    private static func scriptError(_ info: NSDictionary?) -> ScriptError {
        let number = (info?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? 0
        let message =
            info?["NSAppleScriptErrorBriefMessage"] as? String ?? info?["NSAppleScriptErrorMessage"] as? String
            ?? "unknown"
        return ScriptError(number: number, message: message)
    }

    static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// nil for `missing value` (typeType 'msng') and other non-text results.
    private static func optionalString(_ desc: NSAppleEventDescriptor?) -> String? {
        guard let desc else { return nil }
        if desc.descriptorType == fourCC("type") || desc.descriptorType == fourCC("enum") { return nil }
        return desc.stringValue
    }

    private static func optionalStrings(_ desc: NSAppleEventDescriptor?) -> [String?] {
        guard let desc else { return [] }
        guard desc.descriptorType == fourCC("list") else { return [optionalString(desc)] }
        guard desc.numberOfItems > 0 else { return [] }
        return (1...desc.numberOfItems).map { optionalString(desc.atIndex($0)) }
    }

    private static func strings(_ desc: NSAppleEventDescriptor) -> [String] {
        optionalStrings(desc).compactMap { $0 }
    }
}
