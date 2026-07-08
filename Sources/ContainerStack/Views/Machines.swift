import SwiftUI

/// Container machines (micro VMs) — issue #1. List, create, boot/stop,
/// set-default, delete, and open a terminal into one.
struct MachinesView: View {
    @EnvironmentObject var state: AppState
    @State private var showCreateSheet = false

    var body: some View {
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
    }

    private var list: some View {
        CardList(items: state.machines, scrollable: true) { machine in
            MachineRow(machine: machine)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Machine").font(.title3.weight(.semibold))
            Text("A lightweight VM booted from a container image, with your home directory mounted and a stable DNS name.")
                .font(.caption).foregroundStyle(.secondary)

            Form {
                TextField("Image (e.g. alpine:3.22, ubuntu:latest)", text: $image)
                    .textFieldStyle(.roundedBorder)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("CPUs (default: half your cores)", text: $cpus)
                        .textFieldStyle(.roundedBorder)
                    TextField("Memory (default: half your RAM)", text: $memory)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.columns)
            Toggle("Set as default machine", isOn: $setDefault)
                .toggleStyle(.checkbox)

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(4)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary)
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
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if name.isEmpty, let base = image.split(separator: ":").first?.split(separator: "/").last {
                name = String(base)
            }
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