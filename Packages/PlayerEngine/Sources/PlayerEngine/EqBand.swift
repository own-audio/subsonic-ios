import Foundation

/// The fixed 6-band graphic EQ layout. Not user-configurable: a graphic EQ's whole appeal is a
/// small, memorable set of bands, not a parametric editor.
public enum EqBand {
    public static let standardFrequenciesHz: [Double] = [60, 150, 400, 1_000, 2_400, 15_000]

    /// A moderately wide per-band Q — wide enough that adjacent bands (roughly one octave to a
    /// bit over two octaves apart here) blend rather than fighting each other with narrow notches.
    public static let qFactor: Double = 1.0

    public static var count: Int { standardFrequenciesHz.count }

    public static func label(forBandIndex index: Int) -> String {
        let hz = standardFrequenciesHz[index]
        if hz >= 1_000 {
            let khz = hz / 1_000
            return khz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(khz))K" : String(format: "%.1fK", khz)
        }
        return "\(Int(hz))"
    }
}
