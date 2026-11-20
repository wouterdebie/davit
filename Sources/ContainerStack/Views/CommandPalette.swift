import SwiftUI

/// ⌘K global search across every resource. Type to filter; Return opens the
/// top hit; ↑/↓ move. Selecting jumps to the resource's section and, where a
/// detail view exists (containers, images, machines), opens it.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    struct Hit: Identifiable {
        let section: SidebarSection
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        var uid: String { "\(section.rawValue):\(id)" }
    }

    private var allHits: [Hit] {
        var hits: [Hit] = []
        for c in state.containers {
            hits.append(Hit(section: .containers, id: c.id, title: c.id,
                            subtitle: c.shortImage, icon: "shippingbox"))
        }
        for i in state.images {
            hits.append(Hit(section: .images, id: i.id, title: i.shortNameTag,
                            subtitle: i.platforms.joined(separator: " · "), icon: "square.stack.3d.down.forward"))
        }
        for v in state.volumes {
            hits.append(Hit(section: .volumes, id: v.id, title: v.name,
                            subtitle: String(localized: "volume",
                                             comment: "Command palette subtitle for a volume when there is no other detail (noun)."),
                            icon: "externaldrive"))
        }
        for n in state.networks {
            hits.append(Hit(section: .networks, id: n.id, title: n.name,
                            subtitle: n.subnet ?? String(localized: "network",
                                                         comment: "Command palette subtitle for a network without a subnet (noun)."),
                            icon: "network"))
        }
        for m in state.machines {
            hits.append(Hit(section: .machines, id: m.id, title: m.id,
                            subtitle: m.imageReference, icon: "desktopcomputer"))
        }
        return hits
    }

    private var hits: [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allHits }
        return allHits.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search containers, images, volumes, networks, machines…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
                    .onChange(of: query) { selectedIndex = 0 }
            }
            .padding(14)
            Divider()
            if hits.isEmpty {
                Text("No matches").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(hits.enumerated()), id: \.element.uid) { idx, hit in
                                row(hit, selected: idx == selectedIndex)
                                    .id(idx)
                                    .onTapGesture { selectedIndex = idx; openSelected() }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex, anchor: .center) }
                }
            }
        }
        .frame(width: 560)
        .onAppear { fieldFocused = true }
        .onKeyPress(.downArrow) { selectedIndex = min(selectedIndex + 1, max(hits.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selectedIndex = max(selectedIndex - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hit.icon).foregroundStyle(selected ? Color.white : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).foregroundStyle(selected ? Color.white : .primary)
                Text(hit.subtitle).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary).lineLimit(1)
            }
            Spacer()
            Text(hit.section.title).font(.caption2)
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func openSelected() {
        guard selectedIndex < hits.count else { return }
        let hit = hits[selectedIndex]
        state.pendingOpen = (hit.section, hit.id)
        dismiss()
    }
}
