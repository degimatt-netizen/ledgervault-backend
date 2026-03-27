import Foundation

// MARK: - LVFormatting
// Single source of truth for all currency / number formatting across the app.
// All functions are free functions — call them from any View or class without import.

/// Returns the currency symbol (or short prefix) for a given ISO 4217 code.
/// e.g. "USD" → "$", "AED" → "د.إ ", "SEK" → "SEkr "
func ccySymbol(_ code: String) -> String {
    switch code.uppercased() {
    case "USD":                  return "$"
    case "EUR":                  return "€"
    case "GBP":                  return "£"
    case "JPY":                  return "¥"
    case "CHF":                  return "Fr "
    case "CAD":                  return "C$"
    case "AUD":                  return "A$"
    case "NZD":                  return "NZ$"
    case "SGD":                  return "S$"
    case "HKD":                  return "HK$"
    case "AED":                  return "د.إ "
    case "PLN":                  return "zł "
    case "SEK":                  return "SEkr "
    case "NOK":                  return "NOkr "
    case "DKK":                  return "DKkr "
    case "CZK":                  return "Kč "
    default:                     return code + " "
    }
}

/// Formats a monetary value with its currency symbol.
/// e.g. fmtCurrency(1234.5, currency: "USD")  →  "$1,234.50"
func fmtCurrency(_ v: Double, currency: String) -> String {
    ccySymbol(currency) + v.formatted(.number.precision(.fractionLength(2)))
}

/// Formats a USD market price with auto-scaling precision:
/// < $0.001 → 6 dp, < $1 → 4 dp, else → 2 dp.
func fmtPrice(_ p: Double) -> String {
    if p < 0.001 { return "$\(p.formatted(.number.precision(.fractionLength(6))))" }
    if p < 1     { return "$\(p.formatted(.number.precision(.fractionLength(4))))" }
    return "$\(p.formatted(.number.precision(.fractionLength(2))))"
}

/// Returns a percentage string with an explicit "+" for positive values.
/// e.g. pctStr(3.14)  →  "+3.14%", pctStr(-1.0)  →  "-1.00%"
func pctStr(_ v: Double) -> String {
    (v >= 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(2))) + "%"
}

/// Strips unnecessary trailing zeros from a decimal string representation.
/// e.g. smartNum(100.0)  →  "100", smartNum(1.50)  →  "1.5"
func smartNum(_ v: Double, maxDec: Int = 2) -> String {
    if v.truncatingRemainder(dividingBy: 1) == 0 { return String(format: "%.0f", v) }
    var s = String(format: "%.\(maxDec)f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".")  { s.removeLast() }
    return s
}
