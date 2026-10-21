import ArgumentParser
import Contacts
import Darwin
import Foundation

/// S11: what TCC does when this binary runs from Terminal, cron, or launchd.
/// Never prompts unless --request is given. Prints counts only.
struct S11Headless: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s11-headless",
        abstract: "S11: print process context + Contacts authorization status + a contact count (no prompt).")

    @Flag(help: "Call requestAccess if status is notDetermined (observe whether a prompt appears in this context).")
    var request = false

    func run() throws {
        let info = ProcessInfo.processInfo
        let env = info.environment
        print("c2m-spike s11-headless  \(Stamp.iso())")
        print(
            "pid=\(getpid()) ppid=\(getppid()) parent=\(Self.processName(getppid())) uid=\(getuid()) euid=\(geteuid())")
        print("executable=\(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        print(
            "embedded Info.plist bundle id=\(Bundle.main.bundleIdentifier ?? "nil") usage string present=\(Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil)"
        )
        print("stdin tty=\(isatty(STDIN_FILENO) == 1) stdout tty=\(isatty(STDOUT_FILENO) == 1)")
        for key in [
            "TERM_PROGRAM", "XPC_SERVICE_NAME", "LaunchInstanceID", "__CFBundleIdentifier", "SSH_CONNECTION", "SHELL",
        ] {
            print("env \(key)=\(env[key].map { $0.isEmpty ? "(empty)" : $0 } ?? "(unset)")")
        }

        var status = Access.currentStatus
        print("authorization (before)=\(Access.statusName(status))")
        if status.rawValue == 0 && request {
            let granted = Access.requestBlocking(CNContactStore())
            status = Access.currentStatus
            print("requestAccess granted=\(granted) authorization (after)=\(Access.statusName(status))")
        }
        guard status.rawValue == 3 else {
            print("RESULT: no access in this context; count skipped")
            throw ExitCode(3)
        }
        let store = CNContactStore()
        var count = 0
        let fetch = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as any CNKeyDescriptor])
        do {
            try store.enumerateContacts(with: fetch) { _, _ in count += 1 }
            print("RESULT: access OK, unified contacts=\(count)")
        } catch {
            print("RESULT: status authorized but fetch failed: \(describe(error))")
            throw ExitCode(5)
        }
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "?" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
