import Foundation
import Observation

/// The equalizer curve, saved on this device. Every change is pushed to the engine at once, so
/// the sound follows the slider; saving happens on release (`save()`) or on a toggle or preset.
@Observable
@MainActor
public final class EqualizerStore {
    public private(set) var enabled = false
    public private(set) var preampDb: Double = 0
    public private(set) var bandGainsDb: [Double] = Array(repeating: 0, count: EqBand.count)
    public private(set) var presetName: String?

    /// The engine registers here.
    public var onSettingsChanged: ((_ enabled: Bool, _ preampDb: Double, _ bandGainsDb: [Double]) -> Void)?

    private struct Saved: Codable {
        let enabled: Bool
        let preampDb: Double
        let bandGainsDb: [Double]
        let presetName: String?
    }

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "player.equalizer") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.bandGainsDb.count == EqBand.count {
            enabled = saved.enabled
            preampDb = saved.preampDb
            bandGainsDb = saved.bandGainsDb
            presetName = saved.presetName
        }
    }

    public func currentSettings() -> (enabled: Bool, preampDb: Double, bandGainsDb: [Double]) {
        (enabled, preampDb, bandGainsDb)
    }

    public func setEnabled(_ value: Bool) {
        enabled = value
        push()
        save()
    }

    public func setPreampDb(_ value: Double) {
        preampDb = value
        push()
    }

    public func setBandGainDb(_ index: Int, _ value: Double) {
        guard bandGainsDb.indices.contains(index) else { return }
        bandGainsDb[index] = value
        presetName = nil
        push()
    }

    public func applyPreset(_ preset: EqPreset) {
        bandGainsDb = preset.bandGainsDb
        presetName = preset.name
        push()
        save()
    }

    public func save() {
        let saved = Saved(enabled: enabled, preampDb: preampDb, bandGainsDb: bandGainsDb, presetName: presetName)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: key)
    }

    private func push() {
        onSettingsChanged?(enabled, preampDb, bandGainsDb)
    }
}
