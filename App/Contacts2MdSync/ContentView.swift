import SwiftUI

/// Top-level sections of the main window.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case conflicts
    case markdownOnly
    case deletions
    case duplicates
    case allContacts
    case activity

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .conflicts: "Conflicts"
        case .markdownOnly: "Markdown Only"
        case .deletions: "Deletions"
        case .duplicates: "Duplicates"
        case .allContacts: "All Contacts"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .conflicts: "exclamationmark.triangle"
        case .markdownOnly: "doc.text"
        case .deletions: "trash"
        case .duplicates: "person.2"
        case .allContacts: "person.crop.rectangle.stack"
        case .activity: "clock.arrow.circlepath"
        }
    }

    var placeholderDescription: String {
        switch self {
        case .overview: ""
        case .conflicts: "Contacts changed on both sides will be listed here for review."
        case .markdownOnly: "Markdown contact files with no matching Apple contact."
        case .deletions: "Pending deletions awaiting confirmation."
        case .duplicates: "Possible duplicate contacts."
        case .allContacts: "Every synced contact and its markdown file."
        case .activity: "A log of sync runs and changes."
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .overview
    @State private var access = ContactsAccessModel()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .overview {
            case .overview:
                OverviewView(access: access)
            case let item:
                ContentUnavailableView(
                    item.title,
                    systemImage: item.systemImage,
                    description: Text(item.placeholderDescription)
                )
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
