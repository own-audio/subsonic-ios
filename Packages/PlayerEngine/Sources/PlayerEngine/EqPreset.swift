import Foundation

/// A named starting point for the 6 sliders — tapping one is just "set these six numbers,"
/// nothing the server needs to know about (see `EqSettingsDTO.presetName`'s doc comment). Gain
/// values are curves, not measurements; they're a reasonable starting shape per name, not a
/// scientifically tuned one, same spirit as any consumer graphic EQ's presets.
public struct EqPreset: Identifiable, Equatable, Sendable {
    public let name: String
    /// One gain per `EqBand.standardFrequenciesHz`, in dB.
    public let bandGainsDb: [Double]

    public var id: String { name }

    /// `name` is identity — it is what `EqualizerStore` persists as `presetName`, what the
    /// equalizer's accessibility identifiers are built from, and what the "Flat" lookup
    /// compares against. This is what a listener reads.
    public var title: String {
        switch name {
        case "Flat": loc("Flat")
        case "Bass Boost": loc("Bass Boost")
        case "Treble Boost": loc("Treble Boost")
        case "Spoken Word": loc("Spoken Word")
        case "Loudness": loc("Loudness")
        case "High Speed 1": loc("High Speed 1")
        case "High Speed 2": loc("High Speed 2")
        default: name
        }
    }

    public static let all: [EqPreset] = [
        EqPreset(name: "Flat", bandGainsDb: [0, 0, 0, 0, 0, 0]),
        EqPreset(name: "Bass Boost", bandGainsDb: [6, 4, 2, 0, 0, 0]),
        EqPreset(name: "Treble Boost", bandGainsDb: [0, 0, 0, 2, 4, 6]),
        EqPreset(name: "Spoken Word", bandGainsDb: [-4, -2, 3, 4, 3, -2]),
        EqPreset(name: "Loudness", bandGainsDb: [5, 2, 0, 0, 2, 5]),
        EqPreset(name: "High Speed 1", bandGainsDb: [0, 0, 1, 2, 3, 2]),
        EqPreset(name: "High Speed 2", bandGainsDb: [0, -1, 1, 3, 4, 3]),
    ]
}
