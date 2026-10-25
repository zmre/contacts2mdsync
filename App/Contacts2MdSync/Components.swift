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

    /// Actions sit after the message while it keeps ~240 pt; in a narrower
    /// detail column they wrap below it instead of widening the screen.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                text.frame(idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                actions()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    text.frame(maxWidth: .infinity, alignment: .leading)
                    FlowLayout { actions() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var icon: some View { Image(systemName: style.systemImage).foregroundStyle(style.color) }
    private var text: some View { Text(message).textSelection(.enabled) }
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

/// Lays its subviews out left to right at their ideal sizes, wrapping to a
/// new line when the next one would not fit (button bars, chips). A subview
/// wider than the whole width gets that width, so nothing ever extends past
/// the container — an overflowing `HStack` would be centred and spill under
/// the sidebar.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Frames relative to the layout's origin, each centred vertically in its line.
    private func arrange(width: CGFloat?, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let maxWidth = width ?? .infinity
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var lineWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if let last = lines.last, !last.isEmpty, lineWidth + spacing + size.width > maxWidth {
                lines.append([])
                lineWidth = 0
            }
            lineWidth += (lines[lines.count - 1].isEmpty ? 0 : spacing) + size.width
            lines[lines.count - 1].append((index, size))
        }
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var top: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map(\.size.height).max() ?? 0
            var left: CGFloat = 0
            for item in line {
                frames[item.index] = CGRect(
                    origin: CGPoint(x: left, y: top + (height - item.size.height) / 2), size: item.size)
                left += item.size.width + spacing
            }
            widest = max(widest, left - spacing)
            top += height + lineSpacing
        }
        return (frames, CGSize(width: widest, height: max(top - lineSpacing, 0)))
    }
}
