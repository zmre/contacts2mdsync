import SwiftUI

/// Gray (to do) or green (done) dot.
struct StatusDot: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Color.green : Color.secondary)
            .imageScale(.small)
    }
}

/// The small colored dot of docs/ui.md: orange = needs you, red = error, gray = idle.
struct MeaningDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// A label with a right-aligned count; orange dot when it needs review.
struct CountRow: View {
    let title: String
    let count: Int
    let note: String?
    let needsReview: Bool

    init(_ title: String, _ count: Int, note: String? = nil, needsReview: Bool = false) {
        self.title = title
        self.count = count
        self.note = note
        self.needsReview = needsReview
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let note { Text(note).foregroundStyle(.secondary) }
                if needsReview { MeaningDot(color: .orange) }
                Text(count.formatted()).monospacedDigit()
            }
        } label: {
            Text(title)
        }
    }
}

/// A selectable, middle-truncated path.
struct PathText: View {
    let path: String

    init(_ path: String) { self.path = path }

    var body: some View {
        Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
    }
}

/// An inline banner above a screen (docs/ui.md §12).
struct Banner<Actions: View>: View {
    enum Style {
        case info
        case warning
        case error

        var color: Color {
            switch self {
            case .info: .secondary
            case .warning: .orange
            case .error: .red
            }
        }

        var systemImage: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    let style: Style
    let message: String
    @ViewBuilder let actions: () -> Actions

    init(_ style: Style, _ message: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.style = style
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.systemImage).foregroundStyle(style.color)
            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension Banner where Actions == EmptyView {
    init(_ style: Style, _ message: String) {
        self.init(style, message) { EmptyView() }
    }
}

/// `Robert Smith  0.9`.
struct ConfidenceText: View {
    let title: String
    let confidence: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Text(confidence.formatted(.number.precision(.fractionLength(1))))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
