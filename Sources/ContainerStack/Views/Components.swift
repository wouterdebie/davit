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

struct ConsoleView: View {
    let lines: [String]
    var autoScroll = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("console-bottom")
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) {
                if autoScroll {
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
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
