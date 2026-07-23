import SwiftUI

/// Container machines (micro VMs) — issue #1. List, create, boot/stop,
/// set-default, delete, and open a terminal into one.
struct MachinesView: View {
    @EnvironmentObject var state: AppState
    @State private var showCreateSheet = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) { content }
    }

    private var content: some View {
        Group {
            if !state.systemState.isRunning && state.initialLoadDone {
                ServicesStoppedState()
            } else if state.machines.isEmpty && state.initialLoadDone {
                EmptyState(
                    icon: "desktopcomputer",
                    title: "No machines",
                    message: "A container machine is a lightweight VM you can use like a tiny Linux box — with your home directory mounted.",
                    actionLabel: "Create Machine…"
                ) { showCreateSheet = true }
            } else {
                list
            }
        }
        .navigationTitle("Machines")
        .navigationDestination(for: String.self) { id in
            MachineDetailView(machineID: id)
        }
        .onChange(of: state.pendingOpen?.id) { consumePendingOpen() }
        .onAppear { consumePendingOpen() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Machine", systemImage: "plus")
                }
                .help("Create a container machine")
            }
        }
        .sheet(isPresented: $showCreateSheet) { CreateMachineSheet() }
        .task {
            // Harness: `--pose-machine` pushes the first machine's detail view.
            if ProcessInfo.processInfo.arguments.contains("--pose-machine") {
                for _ in 0..<20 {
                    if let first = state.machines.first {
                        path.append(first.id)
                        try? await Task.sleep(for: .seconds(2))
                        FileHandle.standardError.write(Data("POSED machine\n".utf8))
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// ⌘K jumped to a machine: push its detail.
    private func consumePendingOpen() {
        guard state.pendingOpen?.section == .machines, let id = state.pendingOpen?.id else { return }
        state.pendingOpen = nil
        if state.machines.contains(where: { $0.id == id }), path.last != id { path.append(id) }
    }

    private var list: some View {
        CardList(items: state.machines, scrollable: true) { machine in
            HoverRow(action: { path.append(machine.id) }) {
                MachineRow(machine: machine)
            }
                .contextMenu {
                    if machine.isRunning {
                        Button("Stop") {
                            state.perform(machine.id) { try await MachineService.stop(machine.id) }
                        }
                    } else {
                        Button("Boot") {
                            state.perform(machine.id) { try await MachineService.boot(machine.id) }
                        }
                    }
                    if machine.isRunning {
                        Button("Open Terminal") { TerminalLauncher.openMachineShell(machineID: machine.id) }
                    }
                    Button("Set as Default") {
                        state.perform(machine.id) { try await MachineService.setDefault(machine.id) }
                    }
                    .disabled(machine.isDefault)
                    Divider()
                    Button("Copy DNS Name (\(machine.dnsName))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(machine.dnsName, forType: .string)
                    }
                    if let ip = machine.ipAddress {
                        Button("Copy IP (\(ip))") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        state.perform(machine.id) { try await MachineService.delete(machine.id) }
                    }
                }
        }
    }
}

struct MachineRow: View {
    @EnvironmentObject var state: AppState
    let machine: MachineRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(machine.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(machine.id).font(.body.weight(.medium))
                    if machine.isDefault {
                        Text("default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(machine.imageReference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(machine.cpus) CPU · \(formatBytes(Int64(machine.memoryBytes)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if machine.isRunning, let ip = machine.ipAddress {
                    Text(ip).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if state.busyIDs.contains(machine.id) {
                ProgressView().controlSize(.small)
            } else if machine.isRunning {
                Button {
                    state.perform(machine.id) { try await MachineService.stop(machine.id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop machine")
            } else {
                Button {
                    state.perform(machine.id) { try await MachineService.boot(machine.id) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .help("Boot machine")
            }
        }
        .padding(.vertical, 4)
    }
}

struct CreateMachineSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var image = "alpine:3.22"
    @State private var name = ""
    @State private var cpus = ""
    @State private var memory = ""
    @State private var setDefault = false
    @State private var working = false
    @State private var progressText = ""
    @State private var errorText: String?

    private var defaultCPUs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    private var defaultMemoryGB: Int {
        max(1, Int(ProcessInfo.processInfo.physicalMemory / 2 / 1_073_741_824))
    }

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Machine").font(.title3.weight(.semibold))
                Text("A lightweight VM booted from a container image, with your home directory mounted and a stable DNS name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            VStack(spacing: 14) {
                DetailCard(title: "Image & Name", icon: "square.stack.3d.down.forward") {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Image Reference").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. alpine:3.22, ubuntu:latest", text: $image)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: image) {
                                    updateDefaultName(for: image)
                                }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Machine Name").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. alpine", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                DetailCard(title: "Resources", icon: "cpu") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CPUs").font(.caption).foregroundStyle(.secondary)
                                CountStepperControl(
                                    text: $cpus,
                                    placeholder: "\(defaultCPUs)",
                                    defaultValue: defaultCPUs
                                )
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Memory").font(.caption).foregroundStyle(.secondary)
                                MemoryStepperControl(
                                    text: $memory,
                                    allowsEmpty: true,
                                    defaultText: "\(defaultMemoryGB)GB"
                                )
                            }
                            Spacer(minLength: 0)
                        }
                        Text("CPU and memory default to half of your system resources.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                DetailCard(title: "Options", icon: "gearshape") {
                    Toggle(isOn: $setDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set as default machine").font(.callout)
                            Text("Used by container machine commands when no machine name is specified.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.horizontal, 16)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    create()
                } label: {
                    Text("Create & Boot")
                }
                .buttonStyle(.borderedProminent)
                .disabled(image.isEmpty || name.isEmpty || working)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 480)
        .onAppear {
            if name.isEmpty {
                updateDefaultName(for: image)
            }
        }
    }

    private func updateDefaultName(for img: String) {
        if let base = img.split(separator: ":").first?.split(separator: "/").last {
            name = String(base)
        }
    }

    private func create() {
        working = true
        errorText = nil
        progressText = "Starting…"
        Task {
            do {
                try await MachineService.create(
                    image: image,
                    name: name,
                    cpus: Int(cpus),
                    memory: memory.isEmpty ? nil : memory,
                    setDefault: setDefault,
                    progress: { text in await MainActor.run { progressText = text } }
                )
                await state.refreshAll()
                dismiss()
            } catch let e as CLIError {
                errorText = e.message
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
// MARK: - Machine detail

/// Detail view for a machine, mirroring the container detail's structure:
/// actions in the toolbar, StatusDot + chip header, centered segmented tabs,
/// and the shared Inspect tab.
struct MachineDetailView: View {
    @EnvironmentObject var state: AppState
    let machineID: String

    private enum Tab: String, CaseIterable {
        case overview = "Overview"
        case logs = "Logs"
        case stats = "Stats"
        case inspect = "Inspect"
    }
    @State private var showEditSheet = false
    @State private var tab: Tab =
        ProcessInfo.processInfo.arguments.contains("--pose-machine-tab-stats") ? .stats
        : ProcessInfo.processInfo.arguments.contains("--pose-machine-tab-inspect") ? .inspect
        : .overview

    private var machine: MachineRecord? {
        state.machines.first { $0.id == machineID }
    }

    var body: some View {
        Group {
            if let machine {
                VStack(spacing: 0) {
                    header(machine)
                    Divider()
                    tabContent(machine)
                }
            } else {
                EmptyState(icon: "desktopcomputer", title: "Machine removed",
                           message: "This machine no longer exists.")
            }
        }
        .navigationTitle(machineID)
        .sheet(isPresented: $showEditSheet) {
            if let machine {
                EditMachineSheet(machine: machine)
            }
        }
        .toolbar {
            if let machine {
                ToolbarItemGroup(placement: .primaryAction) {
                    if state.busyIDs.contains(machine.id) {
                        // Same trick as containers: a disabled button so the
                        // spinner shares the toolbar capsule's metrics.
                        Button {} label: {
                            ProgressView().controlSize(.small)
                        }
                        .disabled(true)
                    }
                    if machine.isRunning {
                        Button {
                            state.perform(machine.id) { try await MachineService.stop(machine.id) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.help("Stop machine")
                        Button {
                            TerminalLauncher.openMachineShell(machineID: machine.id)
                        } label: {
                            Label("Terminal", systemImage: "terminal")
                        }.help("Open shell in Terminal")
                    } else {
                        Button {
                            state.perform(machine.id) { try await MachineService.boot(machine.id) }
                        } label: {
                            Label("Boot", systemImage: "play.fill")
                        }.help("Boot machine")
                    }
                    Menu {
                        Button("Edit\u{2026}") { showEditSheet = true }
                        Button("Set as Default") {
                            state.perform(machine.id) { try await MachineService.setDefault(machine.id) }
                        }
                        .disabled(machine.isDefault)
                        Divider()
                        Button("Delete", role: .destructive) {
                            state.perform(machine.id) { try await MachineService.delete(machine.id) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func header(_ m: MachineRecord) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                StatusDot(color: m.isRunning ? .green : .secondary, pulsing: m.isRunning)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(m.id).font(.title2.weight(.semibold))
                        Text(m.isRunning ? "Running" : "Stopped")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((m.isRunning ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
                            .foregroundStyle(m.isRunning ? Color.green : Color.secondary)
                        if m.isDefault {
                            Text("Default")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(m.imageReference).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func tabContent(_ m: MachineRecord) -> some View {
        switch tab {
        case .overview: MachineOverviewTab(machine: m)
        case .logs: ContainerLogsTab(containerID: m.id, machine: true)
        case .stats:
            if let backing = m.containerId {
                ContainerStatsTab(machine: m, backing: backing)
            } else {
                EmptyState(icon: "chart.xyaxis.line", title: "No stats",
                           message: "This machine has no backing container yet.")
            }
        case .inspect: InspectTab(kind: "machine", id: m.id)
        }
    }
}

struct MachineOverviewTab: View {
    let machine: MachineRecord

    var body: some View {
        ScrollView { content }
    }

    private var content: some View {
        VStack(spacing: 14) {
            DetailCard(title: "General", icon: "info.circle") {
                InfoRow(label: "ID", value: machine.id, monospaced: true, copyable: true)
                InfoRow(label: "Image", value: machine.imageReference, monospaced: true, copyable: true)
                InfoRow(label: "Platform", value: machine.platform)
                if let created = machine.created {
                    InfoRow(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened))
                }
            }
            DetailCard(title: "Resources", icon: "cpu") {
                InfoRow(label: "CPUs", value: "\(machine.cpus)")
                InfoRow(label: "Memory", value: formatBytes(Int64(machine.memoryBytes)))
                if let disk = machine.diskSize {
                    InfoRow(label: "Disk used", value: formatBytes(Int64(disk)))
                }
                InfoRow(label: "Home mount", value: machine.homeMount == "none" ? "not mounted" : "~/ mounted \(machine.homeMount)")
            }
            DetailCard(title: "Network", icon: "network") {
                if let ip = machine.ipAddress {
                    InfoRow(label: "IP", value: ip, monospaced: true, copyable: true)
                }
                InfoRow(label: "DNS name", value: machine.dnsName, monospaced: true, copyable: true)
            }
            DetailCard(title: "Shell", icon: "terminal") {
                InfoRow(label: "Open a shell", value: "container machine run -n \(machine.id)", monospaced: true, copyable: true)
                if let backing = machine.containerId {
                    InfoRow(label: "Backing container", value: backing, monospaced: true, copyable: true)
                }
            }
        }
        .padding(16)
    }
}


/// Edit a machine's boot config (`container machine set`); the platform
/// applies changes on the next boot.
struct EditMachineSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let machine: MachineRecord

    @State private var cpus = ""
    @State private var memory = ""
    @State private var homeMount = "rw"
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit \(machine.id)").font(.title3.weight(.semibold))
                Text(machine.isRunning
                     ? "Changes apply after the machine is stopped and booted again."
                     : "Changes apply on the next boot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            VStack(spacing: 14) {
                DetailCard(title: "Resources", icon: "cpu") {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CPUs").font(.caption).foregroundStyle(.secondary)
                            CountStepperControl(text: $cpus)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory").font(.caption).foregroundStyle(.secondary)
                            MemoryStepperControl(text: $memory)
                        }
                        Spacer(minLength: 0)
                    }
                }

                DetailCard(title: "Home Directory", icon: "folder") {
                    Picker("Home directory", selection: $homeMount) {
                        Text("Mounted read-write").tag("rw")
                        Text("Mounted read-only").tag("ro")
                        Text("Not mounted").tag("none")
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(16)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 440)
        .onAppear {
            cpus = "\(machine.cpus)"
            // Binary units to match the platform ("64G" = GiB); decimal
            // formatBytes output would silently shrink/grow the value.
            let gib = machine.memoryBytes / 1_073_741_824
            memory = gib >= 1 && machine.memoryBytes % 1_073_741_824 == 0
                ? "\(gib)G" : "\(machine.memoryBytes / 1_048_576)M"
            homeMount = machine.homeMount
        }
    }

    private func save() {
        working = true
        errorText = nil
        Task {
            do {
                try await MachineService.setConfig(
                    machine.id,
                    cpus: Int(cpus),
                    memory: memory,
                    homeMount: homeMount)
                await state.refreshAll()
                dismiss()
            } catch let e as CLIError {
                errorText = e.message
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}
