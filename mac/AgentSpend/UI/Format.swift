import Foundation

enum Format {
    private static func decimal(_ d: Double, _ places: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = places
        f.maximumFractionDigits = places
        return f.string(from: NSNumber(value: d)) ?? "\(d)"
    }

    /// Wh below a kilowatt-hour, kWh above. Keeps the menu bar item narrow.
    static func wh(_ v: Double) -> String {
        v >= 1000 ? "\(decimal(v / 1000, 1)) kWh"
                  : "\(decimal(v, v < 10 ? 2 : 0)) Wh"
    }

    static func usd(_ v: Double) -> String { "$" + decimal(v, v < 10 ? 2 : 0) }

    /// Plain grouped integer — "21,579", not "21.6k". Used where the exact
    /// count matters more than compactness.
    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return "\(decimal(Double(n) / 1e9, 2))B"
        case 1_000_000...:     return "\(decimal(Double(n) / 1e6, 1))M"
        case 1_000...:         return "\(decimal(Double(n) / 1e3, 1))k"
        default:               return "\(n)"
        }
    }

    static func percent(_ fraction: Double, places: Int = 1) -> String {
        decimal(fraction * 100, places) + "%"
    }

    /// A banded estimate, never a bare number — the band is the point.
    static func band(_ lo: Double, _ v: Double, _ hi: Double) -> String {
        "\(wh(v))  (\(wh(lo))–\(wh(hi)))"
    }

    /// Express energy as time spent running a typical US home. At the scales
    /// this app deals in (kWh to hundreds of kWh) a home is the only relatable
    /// anchor — a phone charge or kettle would be thousands of units. One anchor,
    /// scaled minutes → hours → days → weeks so it always reads naturally.
    static func homeEnergy(_ wh: Double, _ e: EnergyModel.Equivalences) -> String {
        let kwh = wh / 1000
        let perDay = e.usHomeKwhPerDay
        let days = kwh / perDay
        let suffix = " of a typical US home"

        if days < 1.0 / 24 {                        // under an hour → minutes
            let mins = days * 24 * 60
            return "≈ \(decimal(max(mins, 0), mins < 10 ? 1 : 0)) min" + suffix
        }
        if days < 1 {                               // under a day → hours
            let hours = days * 24
            return "≈ \(decimal(hours, hours < 10 ? 1 : 0)) hours" + suffix
        }
        if days < 14 {                              // up to two weeks → days
            return "≈ \(decimal(days, days < 10 ? 1 : 0)) days" + suffix
        }
        let weeks = days / 7                         // beyond → weeks
        return "≈ \(decimal(weeks, weeks < 10 ? 1 : 0)) weeks" + suffix
    }
}
