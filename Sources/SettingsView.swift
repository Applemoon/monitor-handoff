import SwiftUI

/// Configure: a name for each input, hiding the unused ones, which input is this Mac and where
/// the monitor goes when this Mac locks or sleeps.
struct SettingsView: View {
    let inputs: [UInt8]
    let own: UInt8?
    let detectedOwn: UInt8?
    @AppStorage("ownInput") private var ownInput = 0
    @AppStorage("onLockInput") private var onLockInput = 0

    var body: some View {
        Form {
            Section("Inputs") {
                ForEach(inputs, id: \.self) { InputRow(code: $0) }
            }
            Picker("This Mac is on", selection: $ownInput) {
                Text("Automatic" + (detectedOwn.map { " (\(Inputs.label($0)))" } ?? "")).tag(0)
                ForEach(inputs, id: \.self) { Text(Inputs.label($0)).tag(Int($0)) }
            }
            Picker("When this Mac locks or sleeps", selection: $onLockInput) {
                Text("Keep the monitor").tag(0)
                ForEach(inputs.filter { $0 != own }, id: \.self) { Text("Switch to \(Inputs.name($0))").tag(Int($0)) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}

private struct InputRow: View {
    let code: UInt8
    @AppStorage private var name: String
    @AppStorage private var hidden: Bool

    init(code: UInt8) {
        self.code = code
        _name = AppStorage(wrappedValue: "", "name.\(code)")
        _hidden = AppStorage(wrappedValue: false, "hidden.\(code)")
    }

    var body: some View {
        HStack {
            Group {
                Text(Inputs.label(code)).frame(width: 60, alignment: .leading)
                TextField("Name", text: $name, prompt: Text(Inputs.label(code))).labelsHidden()
            }
            .opacity(hidden ? 0.5 : 1)
            // The eye of layer lists: open while the input shows in the menu, struck through when hidden.
            Button { hidden.toggle() } label: {
                Image(systemName: hidden ? "eye.slash" : "eye").frame(width: 22)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(hidden ? "Show in the menu" : "Hide from the menu")
        }
    }
}
