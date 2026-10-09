import MusicEngine
import SwiftUI

/// The six-band graphic EQ. Rows of horizontal sliders rather than vertical faders: they read
/// as clearly and need no rotation tricks. The sound follows a slider while it moves; the curve
/// is saved when it is let go.
struct EqualizerView: View {
    let store: EqualizerStore
    @Environment(\.dismiss) private var dismiss

    private static let gainRange = -12.0...12.0
    private static let presetColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Equalizer", isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                        .accessibilityIdentifier("equalizer.enabled")
                }

                Section {
                    gainRow("Preamp", value: store.preampDb, onChange: store.setPreampDb)
                    ForEach(0..<EqBand.count, id: \.self) { index in
                        gainRow(
                            LocalizedStringKey(EqBand.label(forBandIndex: index)),
                            value: store.bandGainsDb[index],
                            onChange: { store.setBandGainDb(index, $0) }
                        )
                        .accessibilityIdentifier("equalizer.band.\(index)")
                    }
                } footer: {
                    Text("Hz. Applies to everything played.")
                }
                .disabled(!store.enabled)

                Section {
                    LazyVGrid(columns: Self.presetColumns, spacing: Theme.Spacing.sm) {
                        ForEach(EqPreset.all) { preset in
                            Button {
                                Haptics.selection()
                                store.applyPreset(preset)
                            } label: {
                                Group {
                                    if store.presetName == preset.name {
                                        Label(preset.title, systemImage: "checkmark")
                                    } else {
                                        Text(preset.title)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("equalizer.preset.\(preset.name)")
                        }
                    }
                    .disabled(!store.enabled)
                } header: {
                    HStack {
                        Text("Presets")
                        Spacer()
                        if store.presetName == nil { Text("Custom") }
                    }
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { reset() }.disabled(!store.enabled)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func reset() {
        store.setPreampDb(0)
        if let flat = EqPreset.all.first(where: { $0.name == "Flat" }) { store.applyPreset(flat) }
        store.save()
    }

    private func gainRow(_ label: LocalizedStringKey, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: Self.gainRange) { editing in
                if !editing { store.save() }
            }
            Text(Self.gainText(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private static func gainText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
