import SwiftUI

/// Memory-size input: numeric field + stepper + MB/GB unit picker, instead of
/// a free-text "1gb". Binds to the platform's memory-string form — binary
/// units, so "8GB" = 8 GiB (Measurement+Parse in apple/container). Accepts
/// any platform-legal string on the way in (bytes, k/m/g/t, "ib" suffixes)
/// and writes back canonical "<n>MB" / "<n>GB".
struct MemoryStepperControl: View {
    @Binding var text: String
    /// When true, an empty bound string means "platform default" and the
    /// field shows `defaultText` as a placeholder; stepping starts from it.
    var allowsEmpty = false
    var defaultText = "1GB"

    private enum Unit: String, CaseIterable, Identifiable {
        case mb = "MB", gb = "GB"
        var id: String { rawValue }
        var mbMultiplier: Int { self == .gb ? 1024 : 1 }
        var step: Int { self == .gb ? 1 : 256 }
    }

    @State private var value = ""   // digits only; "" = default when allowed
    @State private var unit: Unit = .gb
    @State private var lastUnit: Unit = .gb

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholderValue, text: $value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
                .onChange(of: value) { writeBack() }
            Stepper(onIncrement: { step(+1) }, onDecrement: { step(-1) }) { EmptyView() }
                .labelsHidden()
            Picker(selection: $unit) {
                ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: unit) { convertToUnit() }
        }
        .onAppear { syncFromText() }
        .onChange(of: text) {
            // Only re-sync on external changes (load/reset), not our own echo.
            if text != canonical() { syncFromText() }
        }
    }

    private var placeholderValue: String {
        guard allowsEmpty, let (v, u) = Self.parse(defaultText) else { return "" }
        return unit == u ? "\(v)" : "\(v * u.mbMultiplier / unit.mbMultiplier)"
    }

    private func syncFromText() {
        if text.isEmpty, allowsEmpty {
            value = ""
            unit = Self.parse(defaultText)?.1 ?? .gb
        } else if let (v, u) = Self.parse(text) {
            value = "\(v)"
            unit = u
        }
        lastUnit = unit
    }

    private func step(_ direction: Int) {
        let current = Int(value)
            ?? (allowsEmpty ? Self.parse(defaultText).map { $0.0 * $0.1.mbMultiplier / unit.mbMultiplier } : nil)
            ?? 0
        value = "\(max(unit.step, current + direction * unit.step))"
    }

    private func convertToUnit() {
        defer { lastUnit = unit }
        guard let v = Int(value), lastUnit != unit else { writeBack(); return }
        value = unit == .mb ? "\(v * 1024)" : "\(max(1, v / 1024))"
        writeBack()
    }

    private func writeBack() {
        text = canonical()
    }

    private func canonical() -> String {
        guard let v = Int(value), v > 0 else { return allowsEmpty ? "" : text }
        return "\(v)\(unit.rawValue)"
    }

    /// Parse any platform-accepted memory string into a whole (value, MB/GB)
    /// pair — GB when it divides evenly, MB otherwise.
    private static func parse(_ s: String) -> (Int, Unit)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.prefix { "0123456789.".contains($0) }
        guard let number = Double(digits), number > 0 else { return nil }
        let suffix = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let mbPerUnit: Double
        switch suffix.first {
        case nil, "b": mbPerUnit = 1.0 / 1_048_576
        case "k": mbPerUnit = 1.0 / 1024
        case "m": mbPerUnit = 1
        case "g": mbPerUnit = 1024
        case "t": mbPerUnit = 1024 * 1024
        default: return nil
        }
        let mb = max(1, Int((number * mbPerUnit).rounded()))
        return mb % 1024 == 0 ? (mb / 1024, .gb) : (mb, .mb)
    }
}

/// Count input with a stepper for sheets (Settings has SteppedCountField).
/// Empty is allowed and means "platform default", shown as the placeholder.
struct CountStepperControl: View {
    @Binding var text: String
    var placeholder = ""
    var defaultValue = 4
    var range: ClosedRange<Int> = 1...64

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
            Stepper(onIncrement: { step(+1) }, onDecrement: { step(-1) }) { EmptyView() }
                .labelsHidden()
        }
    }

    private func step(_ direction: Int) {
        let current = Int(text) ?? defaultValue
        text = "\(min(range.upperBound, max(range.lowerBound, current + direction)))"
    }
}
