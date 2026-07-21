import Foundation

/// Layer 1 built-in text expansions, run BEFORE the phonemizer: rate
/// abbreviations, currency, and numbers-to-words.
///
/// Owning number expansion here also sidesteps a bug in the upstream MisakiSwift
/// phonemizer, whose number-to-words table is missing "twenty" - so it renders
/// 20-29 without the tens word ("25" -> "five", "20" -> silent). By spelling
/// numbers ourselves the phonemizer only ever sees words it handles correctly.
enum TextExpansions {

    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = expandRates(in: text)   // "$15/mo" -> "$15 per month"
        result = expandCurrency(in: result)  // "$15"    -> "15 dollars"
        result = expandNumbers(in: result)   // "15"     -> "fifteen"
        return result
    }

    // MARK: - Rates

    private static let rateWords: [(String, String)] = [
        ("/mo", " per month"), ("/yr", " per year"), ("/wk", " per week"),
        ("/hr", " per hour"), ("/day", " per day"), ("/min", " per minute"),
        ("/sec", " per second"),
    ]

    private static func expandRates(in text: String) -> String {
        var result = text
        for (abbreviation, spoken) in rateWords {
            // Only when attached to a preceding letter/number (e.g. "$15/mo",
            // "3/day") and at a word boundary, so paths like "site.com/monthly"
            // are left alone.
            let pattern = "(?<=[\\p{L}\\p{N}])"
                + NSRegularExpression.escapedPattern(for: abbreviation)
                + "\\b"
            result = replace(pattern: pattern, in: result, caseInsensitive: true) { _ in spoken }
        }
        return result
    }

    // MARK: - Currency

    private static func expandCurrency(in text: String) -> String {
        var result = text
        // "$15.50" -> "15 dollars and 50 cents"
        result = replace(pattern: "\\$(\\d[\\d,]*)\\.(\\d{2})\\b", in: result) { groups in
            "\(groups[1]) dollars and \(groups[2]) cents"
        }
        // "$15" or "$15.5" -> "15 dollars"
        result = replace(pattern: "\\$(\\d[\\d,]*(?:\\.\\d+)?)", in: result) { groups in
            "\(groups[1]) dollars"
        }
        return result
    }

    // MARK: - Numbers

    private static func expandNumbers(in text: String) -> String {
        // Standalone integers/decimals, optional thousands commas.
        replace(pattern: "\\b\\d[\\d,]*(?:\\.\\d+)?\\b", in: text) { groups in
            words(forNumberToken: groups[0])
        }
    }

    /// Convert a matched numeric token ("25", "1,024", "3.14") to spoken words.
    static func words(forNumberToken token: String) -> String {
        let cleaned = token.replacingOccurrences(of: ",", with: "")
        if let dot = cleaned.firstIndex(of: ".") {
            let intPart = String(cleaned[..<dot])
            let fracPart = String(cleaned[cleaned.index(after: dot)...])
            let intWords = intPart.isEmpty ? "zero" : (Int(intPart).map(cardinal) ?? spellDigits(intPart))
            let fracWords = fracPart.map(digitWord).joined(separator: " ")
            return "\(intWords) point \(fracWords)"
        }
        // Fall back to digit-by-digit if it overflows Int (very long strings).
        return Int(cleaned).map(cardinal) ?? spellDigits(cleaned)
    }

    private static func spellDigits(_ digits: String) -> String {
        digits.compactMap { $0.isNumber ? digitWord($0) : nil }.joined(separator: " ")
    }

    private static func digitWord(_ character: Character) -> String {
        ones[min(max(character.wholeNumberValue ?? 0, 0), 9)]
    }

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]
    private static let scales: [(Int, String)] = [
        (1_000_000_000_000, "trillion"), (1_000_000_000, "billion"),
        (1_000_000, "million"), (1_000, "thousand"),
    ]

    /// Cardinal number-to-words. Correct for the full Int range (the "twenty"
    /// the phonemizer omits lives at tens[2]).
    static func cardinal(_ number: Int) -> String {
        if number < 0 { return "minus " + cardinal(-number) }
        if number < 20 { return ones[number] }
        if number < 100 {
            let tensWord = tens[number / 10]
            let onesDigit = number % 10
            return onesDigit == 0 ? tensWord : "\(tensWord)-\(ones[onesDigit])"
        }
        if number < 1000 {
            let hundreds = number / 100
            let remainder = number % 100
            return remainder == 0
                ? "\(ones[hundreds]) hundred"
                : "\(ones[hundreds]) hundred \(cardinal(remainder))"
        }
        for (value, word) in scales where number >= value {
            let quotient = number / value
            let remainder = number % value
            return remainder == 0
                ? "\(cardinal(quotient)) \(word)"
                : "\(cardinal(quotient)) \(word) \(cardinal(remainder))"
        }
        return String(number)
    }

    // MARK: - Regex helper

    /// Replace every match of `pattern`, computing each replacement from the
    /// match's capture groups (group 0 is the whole match). Replacements are
    /// applied right-to-left so earlier match ranges stay valid.
    private static func replace(
        pattern: String,
        in text: String,
        caseInsensitive: Bool = false,
        _ transform: ([String]) -> String
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let matches = regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: index), in: result) {
                    groups.append(String(result[groupRange]))
                } else {
                    groups.append("")
                }
            }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }
}
