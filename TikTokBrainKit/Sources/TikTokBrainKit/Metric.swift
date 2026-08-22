// Metric.swift
//
// Recipes arrive in whatever units the creator spoke — cups, ounces, °F — and the kitchen
// this app cooks in is European. This rewrites US quantities inside free text to grams,
// millilitres, °C and centimetres at display time, so every recipe already saved reads
// metric without a re-analysis. Spoons are left alone: "1 tsp" is how European recipes are
// written too, and "5 ml salt" is nobody's recipe.

import Foundation

public enum Metric {
    /// `text` with every US quantity rewritten in metric. Text with none comes back unchanged.
    public static func localize(_ text: String) -> String {
        temperature(quantity(text))
    }

    // MARK: - Quantities

    // A number (including "1 1/2", "1½", "½", "0.5"), an optional range, then a unit.
    private static let quantityPattern = try! NSRegularExpression(
        pattern: #"(?<!\w)(\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?\s?[½¼¾⅓⅔⅛]?|[½¼¾⅓⅔⅛])(?:\s*(?:-|–|to)\s*(\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?\s?[½¼¾⅓⅔⅛]?|[½¼¾⅓⅔⅛]))?\s*(fl\.?\s*oz\.?|ounces?|oz\.?|pounds?|lbs?\.?|cups?|pints?|quarts?|gallons?|inch(?:es)?)(?!\w)"#,
        options: [.caseInsensitive]
    )

    private static func quantity(_ text: String) -> String {
        rewrite(text, with: quantityPattern) { match, source in
            guard let low = number(match, 1, in: source), let unit = group(match, 3, in: source) else { return nil }
            let high = number(match, 2, in: source)
            let convert = conversion(for: unit)
            let a = convert.scale * low
            if let high {
                return Self.range(a, convert.scale * high, format: convert.format)
            }
            return convert.format(a)
        }
    }

    private static func conversion(for unit: String) -> (scale: Double, format: (Double) -> String) {
        let u = unit.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
        switch u {
        case "floz": return (29.5735, millilitres)
        case "oz", "ounce", "ounces": return (28.3495, grams)
        case "lb", "lbs", "pound", "pounds": return (453.592, grams)
        case "cup", "cups": return (240, millilitres)
        case "pint", "pints": return (473.176, millilitres)
        case "quart", "quarts": return (946.353, millilitres)
        case "gallon", "gallons": return (3785.41, millilitres)
        default: return (2.54, centimetres)   // inch, inches
        }
    }

    // MARK: - Temperature

    private static let temperaturePattern = try! NSRegularExpression(
        pattern: #"(?<!\w)(\d{2,3})(?:\s*(?:-|–|to)\s*(\d{2,3}))?\s*(?:°|º)\s*F(?!\w)|(?<!\w)(\d{2,3})(?:\s*(?:-|–|to)\s*(\d{2,3}))?\s*degrees?\s*(?:F(?!\w)|Fahrenheit)"#,
        options: [.caseInsensitive]
    )

    private static func temperature(_ text: String) -> String {
        rewrite(text, with: temperaturePattern) { match, source in
            let low = number(match, 1, in: source) ?? number(match, 3, in: source)
            let high = number(match, 2, in: source) ?? number(match, 4, in: source)
            guard let low else { return nil }
            // Oven temperatures round to tens (350°F → 180°C, 400 → 200, 425 → 220); anything
            // below 100°C — proofing water, tempering — keeps fives.
            let c = { (f: Double) -> Double in
                let celsius = (f - 32) * 5 / 9
                return roundTo(celsius, celsius < 100 ? 5 : 10)
            }
            if let high { return "\(whole(c(low)))–\(whole(c(high)))°C" }
            return "\(whole(c(low)))°C"
        }
    }

    // MARK: - Formatting

    /// Cookbook rounding: 8 oz reads 225 g, 1 lb 450 g, 2 lb 900 g, 3 lb 1.4 kg.
    private static func grams(_ g: Double) -> String {
        if g >= 1000 { return "\(oneDecimal(g / 1000)) kg" }
        return "\(whole(roundTo(g, g < 300 ? 5 : 25))) g"
    }

    private static func millilitres(_ ml: Double) -> String {
        if ml >= 1000 { return "\(oneDecimal(ml / 1000)) l" }
        return "\(whole(ml < 10 ? ml.rounded() : roundTo(ml, 5))) ml"
    }

    private static func centimetres(_ cm: Double) -> String {
        "\(oneDecimal(roundTo(cm, 0.5))) cm"
    }

    /// "55–85 g": the unit once, after the range.
    private static func range(_ a: Double, _ b: Double, format: (Double) -> String) -> String {
        let left = format(a), right = format(b)
        guard let unit = right.split(separator: " ").last, left.hasSuffix(" \(unit)") else { return "\(left)–\(right)" }
        return "\(left.dropLast(unit.count + 1))–\(right)"
    }

    private static func roundTo(_ value: Double, _ step: Double) -> Double { (value / step).rounded() * step }
    private static func whole(_ value: Double) -> String { String(Int(value.rounded())) }
    private static func oneDecimal(_ value: Double) -> String {
        let s = String(format: "%.1f", value)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    // MARK: - Regex plumbing

    private static func rewrite(_ text: String, with regex: NSRegularExpression,
                               _ replacement: (NSTextCheckingResult, String) -> String?) -> String {
        let ns = text as NSString
        var out = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let new = replacement(match, text), let r = Range(match.range, in: out) else { continue }
            out.replaceSubrange(r, with: new)
        }
        return out
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in source: String) -> String? {
        guard index < match.numberOfRanges, let r = Range(match.range(at: index), in: source) else { return nil }
        return String(source[r])
    }

    /// "1 1/2", "1½", "½", "0.5", "1,5" → a Double.
    private static func number(_ match: NSTextCheckingResult, _ index: Int, in source: String) -> Double? {
        guard let raw = group(match, index, in: source) else { return nil }
        var total = 0.0, seen = false
        var rest = raw.replacingOccurrences(of: ",", with: ".")
        for (glyph, value) in [("½", 0.5), ("¼", 0.25), ("¾", 0.75), ("⅓", 1.0 / 3), ("⅔", 2.0 / 3), ("⅛", 0.125)] where rest.contains(glyph) {
            total += value; seen = true
            rest = rest.replacingOccurrences(of: glyph, with: " ")
        }
        for part in rest.split(separator: " ") {
            if let slash = part.firstIndex(of: "/"), let n = Double(part[..<slash]), let d = Double(part[part.index(after: slash)...]), d != 0 {
                total += n / d; seen = true
            } else if let v = Double(part) {
                total += v; seen = true
            }
        }
        return seen ? total : nil
    }
}
