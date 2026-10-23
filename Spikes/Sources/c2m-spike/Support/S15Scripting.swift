import Foundation

/// Contacts.app scripting for the S15 field writes (spike S15): the
/// Apple Events equivalents of the CNSaveRequest operations that fail with
/// NSCocoaErrorDomain 134092 on cards that have a note.
///
/// Same mechanism as the S12 reader: one compiled `NSAppleScript`, handlers
/// called with a subroutine Apple Event whose arguments are descriptors.
/// Person ids, group ids, labeled-value ids and values are NEVER spliced into
/// script source. Main thread only.
///
/// Callers must verify every target (CNContactStore AND Contacts.app, see
/// `S14NotesGuard.checkTargets`) immediately before each write handler.
final class S15Scripting {
    /// Handler names are lowercase (AppleScript folds handler identifiers).
    /// Write handlers end with `save`; Contacts.app applies scripting edits to
    /// its in-memory book and persists them on `save`.
    static let source = """
        on lastjob(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\treturn {last name of p, job title of p}
        \tend tell
        end lastjob

        on setnames(pid, ln, jt)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\tset last name of p to ln
        \t\tset job title of p to jt
        \t\tsave
        \tend tell
        \treturn true
        end setnames

        on emailinfo(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\treturn {id of every email of p, label of every email of p, value of every email of p}
        \tend tell
        end emailinfo

        on phoneinfo(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\treturn {id of every phone of p, label of every phone of p, value of every phone of p}
        \tend tell
        end phoneinfo

        on urlinfo(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\treturn {id of every url of p, label of every url of p, value of every url of p}
        \tend tell
        end urlinfo

        on addemail(pid, lbl, val)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\tset e to make new email at end of emails of p with properties {label:lbl, value:val}
        \t\tset eid to ""
        \t\ttry
        \t\t\tset eid to id of e
        \t\tend try
        \t\tsave
        \t\treturn eid
        \tend tell
        end addemail

        on setphonebyid(pid, phid, val)
        \ttell application id "com.apple.AddressBook"
        \t\tset value of phone id phid of person id pid to val
        \t\tsave
        \tend tell
        \treturn true
        end setphonebyid

        on setphoneat(pid, idx, val)
        \ttell application id "com.apple.AddressBook"
        \t\tset value of phone idx of person id pid to val
        \t\tsave
        \tend tell
        \treturn true
        end setphoneat

        on addurl(pid, lbl, val)
        \ttell application id "com.apple.AddressBook"
        \t\tset p to person id pid
        \t\tset u to make new url at end of urls of p with properties {label:lbl, value:val}
        \t\tset uid to ""
        \t\ttry
        \t\t\tset uid to id of u
        \t\tend try
        \t\tsave
        \t\treturn uid
        \tend tell
        end addurl

        on deleteurlbyid(pid, uid)
        \ttell application id "com.apple.AddressBook"
        \t\tdelete url id uid of person id pid
        \t\tsave
        \tend tell
        \treturn true
        end deleteurlbyid

        on groupname(gid)
        \ttell application id "com.apple.AddressBook" to return name of group id gid
        end groupname

        on groupidsof(pid)
        \ttell application id "com.apple.AddressBook" to return id of every group of person id pid
        end groupidsof

        on addtogroup(pid, gid)
        \ttell application id "com.apple.AddressBook"
        \t\tadd person id pid to group id gid
        \t\tsave
        \tend tell
        \treturn true
        end addtogroup

        on removefromgroup(pid, gid)
        \ttell application id "com.apple.AddressBook"
        \t\tremove person id pid from group id gid
        \t\tsave
        \tend tell
        \treturn true
        end removefromgroup

        on personexists(pid)
        \ttell application id "com.apple.AddressBook" to return exists person id pid
        end personexists

        on deleteperson(pid)
        \ttell application id "com.apple.AddressBook"
        \t\tdelete person id pid
        \t\tsave
        \tend tell
        \treturn true
        end deleteperson
        """

    /// One labeled value as Contacts.app scripting reports it.
    struct Entry: Equatable {
        var id: String
        var label: String?
        var value: String
    }

    private let handlers: ContactsScripting

    init() throws {
        handlers = try ContactsScripting(source: Self.source)
    }

    private static func text(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: value) }

    // MARK: Reads

    func lastNameAndJobTitle(_ pid: String) throws -> (lastName: String?, jobTitle: String?) {
        let list = try handlers.call("lastjob", Self.text(pid))
        guard list.numberOfItems == 2 else { throw SpikeError("lastjob returned \(list.numberOfItems) items") }
        return (ContactsScripting.optionalString(list.atIndex(1)), ContactsScripting.optionalString(list.atIndex(2)))
    }

    func emails(_ pid: String) throws -> [Entry] { try entries("emailinfo", pid) }
    func phones(_ pid: String) throws -> [Entry] { try entries("phoneinfo", pid) }
    func urls(_ pid: String) throws -> [Entry] { try entries("urlinfo", pid) }

    private func entries(_ handler: String, _ pid: String) throws -> [Entry] {
        let list = try handlers.call(handler, Self.text(pid))
        guard list.numberOfItems == 3 else { throw SpikeError("\(handler) returned \(list.numberOfItems) items") }
        let ids = ContactsScripting.optionalStrings(list.atIndex(1))
        let labels = ContactsScripting.optionalStrings(list.atIndex(2))
        let values = ContactsScripting.optionalStrings(list.atIndex(3))
        guard ids.count == labels.count, ids.count == values.count else {
            throw SpikeError("\(handler): id/label/value counts differ (\(ids.count)/\(labels.count)/\(values.count))")
        }
        return ids.indices.map { Entry(id: ids[$0] ?? "", label: labels[$0], value: values[$0] ?? "") }
    }

    func groupName(_ gid: String) throws -> String? {
        ContactsScripting.optionalString(try handlers.call("groupname", Self.text(gid)))
    }

    func groupIDs(of pid: String) throws -> [String] {
        ContactsScripting.optionalStrings(try handlers.call("groupidsof", Self.text(pid))).compactMap { $0 }
    }

    func personExists(_ pid: String) throws -> Bool {
        try handlers.call("personexists", Self.text(pid)).booleanValue
    }

    // MARK: Writes (caller verifies the target first)

    func setNames(_ pid: String, lastName: String, jobTitle: String) throws {
        _ = try handlers.call("setnames", Self.text(pid), Self.text(lastName), Self.text(jobTitle))
    }

    /// Returns the new email's scripting `id` ("" if Contacts.app did not give one).
    func addEmail(_ pid: String, label: String, value: String) throws -> String {
        ContactsScripting.optionalString(try handlers.call("addemail", Self.text(pid), Self.text(label), Self.text(value)))
            ?? ""
    }

    func setPhone(_ pid: String, phoneID: String, value: String) throws {
        _ = try handlers.call("setphonebyid", Self.text(pid), Self.text(phoneID), Self.text(value))
    }

    /// `index` is 1-based (AppleScript).
    func setPhone(_ pid: String, index: Int, value: String) throws {
        _ = try handlers.call("setphoneat", Self.text(pid), NSAppleEventDescriptor(int32: Int32(index)), Self.text(value))
    }

    func addURL(_ pid: String, label: String, value: String) throws -> String {
        ContactsScripting.optionalString(try handlers.call("addurl", Self.text(pid), Self.text(label), Self.text(value)))
            ?? ""
    }

    func deleteURL(_ pid: String, urlID: String) throws {
        _ = try handlers.call("deleteurlbyid", Self.text(pid), Self.text(urlID))
    }

    func addToGroup(_ pid: String, groupID: String) throws {
        _ = try handlers.call("addtogroup", Self.text(pid), Self.text(groupID))
    }

    func removeFromGroup(_ pid: String, groupID: String) throws {
        _ = try handlers.call("removefromgroup", Self.text(pid), Self.text(groupID))
    }

    func deletePerson(_ pid: String) throws {
        _ = try handlers.call("deleteperson", Self.text(pid))
    }
}
