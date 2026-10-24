import AppKit
import Contacts2MdCLI
import Foundation

// Finder and Contacts.app from the main window (Reveal, Open in Contacts).

extension AppModel {
    /// Opens each card in Contacts.app; rescans when the app is active again.
    func openInContacts(cardIDs: [String]) {
        let urls = UIFormat.contactsURLs(cardIDs: cardIDs)
        guard !urls.isEmpty else { return }
        rescanOnActivate = true
        for url in urls { NSWorkspace.shared.open(url) }
    }

    /// Called when the app becomes active.
    func didBecomeActive() async {
        guard rescanOnActivate else { return }
        rescanOnActivate = false
        await check()
    }

    /// Selects `path` (root-relative) in Finder.
    func revealInFinder(path: String) {
        guard let root = rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appending(path: path)])
    }

    func revealRoot() {
        guard let root = rootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealBackups() {
        guard let folder = data?.backupsDirectory else { return }
        let target = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) ? folder : nil
        NSWorkspace.shared.activateFileViewerSelecting([target ?? folder.deletingLastPathComponent()])
    }

    /// Shows `item` in the inspector (opening it when asked).
    func inspect(_ item: InspectorItem?, open: Bool = false) {
        inspected = item
        if open, item != nil { isInspectorPresented = true }
    }
}
