import SwiftUI

// MARK: - Status indicators

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if pulsing {
                    Circle()
                        .stroke(color.opacity(pulse ? 0 : 0.55), lineWidth: 3)
                        .scaleEffect(pulse ? 2.0 : 1.0)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                }
            }
            .onAppear { pulse = true }
    }
}

struct StateChip: View {
    let state: ContainerState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.color.opacity(0.15), in: Capsule())
            .foregroundStyle(state == .stopped ? Color.secondary : state.color)
    }
}

// MARK: - Detail info rows

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false
    var copyable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            if monospaced {
                Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            } else {
                Text(value).textSelection(.enabled)
            }
            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
                Text(title).font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Empty states

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(.quaternary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServicesStoppedState: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        EmptyState(
            icon: "powersleep",
            title: "Container services are stopped",
            message: "Start Apple's container services to manage containers, images and more.",
            actionLabel: "Start Services"
        ) {
            state.toggleSystem()
        }
    }
}

// MARK: - Log / console text view

/// A log/console view backed by NSTextView: native multi-line selection and
/// copy, and ANSI SGR color escapes (e.g. `ESC[92mINFO ESC[0m`) rendered as
/// real colors instead of literal `[92m…` noise.
struct ConsoleView: NSViewRepresentable {
    let lines: [String]
    var autoScroll = true

    private static let fontSize: CGFloat = 11.5

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isRichText = false
        tv.textContainer?.widthTracksTextView = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let coord = context.coordinator

        // Rebuild fully if the buffer was reset/replaced (tail change, boot
        // toggle); otherwise append only the new lines so selection survives.
        if lines.count < coord.rendered || !coord.prefixMatches(lines) {
            storage.setAttributedString(Self.render(Array(lines)))
            coord.rendered = lines.count
            coord.first = lines.first
        } else if lines.count > coord.rendered {
            let fresh = Array(lines[coord.rendered...])
            let piece = Self.render(fresh, leadingNewline: coord.rendered > 0)
            storage.append(piece)
            coord.rendered = lines.count
        } else {
            return  // nothing changed
        }

        if autoScroll { tv.scrollToEndOfDocument(nil) }
    }

    final class Coordinator {
        var rendered = 0
        var first: String?
        func prefixMatches(_ lines: [String]) -> Bool { lines.first == first || rendered == 0 }
    }

    // MARK: ANSI rendering

    private static func render(_ lines: [String], leadingNewline: Bool = false) -> NSAttributedString {
        let base = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if leadingNewline || i > 0 { out.append(NSAttributedString(string: "\n")) }
            appendANSI(line, to: out, baseFont: base)
        }
        return out
    }

    /// Standard/bright ANSI foreground colors, chosen to read on the dark
    /// console background.
    private static let palette: [NSColor] = [
        .secondaryLabelColor, .systemRed, .systemGreen, .systemYellow,
        .systemBlue, .systemPurple, .systemTeal, .labelColor,
    ]

    private static func appendANSI(_ line: String, to out: NSMutableAttributedString, baseFont: NSFont) {
        let def = NSColor.labelColor
        var color = def
        var bold = false
        var buffer = ""
        let chars = Array(line)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let font = bold ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold) : baseFont
            out.append(NSAttributedString(string: buffer, attributes: [.foregroundColor: color, .font: font]))
            buffer = ""
        }

        while i < chars.count {
            // An SGR escape: ESC [ <params> m
            if chars[i] == "\u{1b}", i + 1 < chars.count, chars[i + 1] == "[" {
                var j = i + 2
                var code = ""
                while j < chars.count, chars[j] != "m" { code.append(chars[j]); j += 1 }
                if j < chars.count {   // found the terminating 'm'
                    flush()
                    applySGR(code, color: &color, bold: &bold, default: def)
                    i = j + 1
                    continue
                }
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
    }

    private static func applySGR(_ code: String, color: inout NSColor, bold: inout Bool, default def: NSColor) {
        let params = code.split(separator: ";").map { Int($0) ?? 0 }
        if params.isEmpty { color = def; bold = false; return }   // ESC[m == reset
        for p in params {
            switch p {
            case 0: color = def; bold = false
            case 1: bold = true
            case 22: bold = false
            case 30...37: color = palette[p - 30]
            case 39: color = def
            case 90...97: color = palette[p - 90]
            default: break   // background colors, italics, etc. — ignored
            }
        }
    }
}

// MARK: - Small form helpers used by sheets

struct KeyValueEditor: View {
    let keyPlaceholder: String
    let valuePlaceholder: String
    @Binding var pairs: [KVPair]
    var separator = "→"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($pairs) { $pair in
                HStack(spacing: 8) {
                    TextField(text: $pair.key, prompt: Text(keyPlaceholder)) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text(separator).foregroundStyle(.tertiary)
                    TextField(text: $pair.value, prompt: Text(valuePlaceholder)) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button {
                        pairs.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button {
                pairs.append(KVPair())
            } label: {
                Label(pairs.isEmpty ? "Add" : "Add another", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .font(.callout)
            .padding(.top, 2)
        }
    }
}

struct KVPair: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""
}

extension View {
    /// The background poll runs every few seconds and is effectively instant —
    /// rows update in place. A toolbar spinner for it either reflowed the
    /// toolbar (conditional item) or left a visible empty pill (reserved slot),
    /// so the refresh is silent. Kept as a no-op so call sites stay put.
    func refreshIndicator(_ refreshing: Bool) -> some View { self }
}

// MARK: - Custom scroll-based list (OrbStack-style rows with hover highlight)

struct CardList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var scrollable = true
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if scrollable {
            ScrollView { inner }
        } else {
            inner
        }
    }

    private var inner: some View {
        LazyVStack(spacing: 2) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(10)
    }
}

struct HoverRow<Content: View>: View {
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowBody }
                    .buttonStyle(.plain)
            } else {
                rowBody
            }
        }
        .onHover { hovering = $0 }
    }

    private var rowBody: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(
                hovering ? AnyShapeStyle(.primary.opacity(0.055)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
