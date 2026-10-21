import Foundation
import SpikeShim

/// A user-facing failure. `exitCode` follows architecture §15 where it makes
/// sense (3 = not runnable, e.g. no Contacts access).
struct SpikeError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    var exitCode: Int32 = 1

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    var description: String { message }
    var errorDescription: String? { message }
}

/// Runs `body`, converting Objective-C exceptions (e.g.
/// CNContactPropertyNotFetchedException) into Swift errors instead of crashing.
func catchingObjC<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, any Error>?
    var objcError: NSError?
    let ok = C2MSpikeTry(
        {
            result = Result { try body() }
        }, &objcError)
    if !ok {
        throw objcError ?? SpikeError("Unknown Objective-C exception")
    }
    guard let result else { throw SpikeError("catchingObjC: body did not run") }
    return try result.get()
}

/// Short, PII-free description of an error: domain, code, and (for shim
/// exceptions) the exception name/reason.
func describe(_ error: any Error) -> String {
    let ns = error as NSError
    if ns.domain == C2MSpikeShimErrorDomain {
        let name = ns.userInfo[C2MSpikeExceptionNameKey] as? String ?? "?"
        let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ""
        return "ObjC exception \(name): \(reason)"
    }
    if let spike = error as? SpikeError { return spike.message }
    return "\(ns.domain) code \(ns.code): \(ns.localizedDescription)"
}
