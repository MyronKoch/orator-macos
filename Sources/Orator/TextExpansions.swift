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
        result = expandSlash(in: result)     // "and/or" -> "and slash or"
        result = expandTimes(in: result)     // "9:15"   -> "nine fifteen"
        result = expandOrdinals(in: result)  // "22nd"   -> "twenty-second"
        result = expandNumbers(in: result)   // "15"     -> "fifteen"
        return result
    }

    // MARK: - Times

    /// Clock times, BEFORE `expandNumbers`. That pass matches each side of the
    /// colon separately and leaves the colon in place ("04:12" -> "four:twelve"),
    /// which is not how anyone says a time.
    ///
    /// Minutes are constrained to 00-59 so ratios and scores ("3:75") are left
    /// for the ordinary number pass.
    private static func expandTimes(in text: String) -> String {
        replace(pattern: "\\b(\\d{1,2}):([0-5]\\d)(?::([0-5]\\d))?\\b", in: text) { groups in
            let hour = spokenHour(groups[1])
            let minute = spokenMinutes(groups[2], allowOClock: groups[3].isEmpty)
            let second = groups[3].isEmpty ? "" : " " + spokenMinutes(groups[3], allowOClock: false)
            return "\(hour) \(minute)\(second)"
        }
    }

    /// A written leading zero is spoken ("04:12" is "oh four twelve").
    private static func spokenHour(_ raw: String) -> String {
        guard let value = Int(raw) else { return raw }
        let hasLeadingZero = raw.count > 1 && raw.hasPrefix("0")
        return hasLeadingZero ? "oh \(cardinal(value))" : cardinal(value)
    }

    private static func spokenMinutes(_ raw: String, allowOClock: Bool) -> String {
        guard let value = Int(raw) else { return raw }
        if value == 0 { return allowOClock ? "o'clock" : "hundred" }
        // 01-09 keeps its spoken zero: "9:05" is "nine oh five".
        return value < 10 ? "oh \(cardinal(value))" : cardinal(value)
    }

    // MARK: - Ordinals

    /// "22nd" -> "twenty-second". These never matched `expandNumbers` at all:
    /// its `\b\d[\d,]*\b` needs a word boundary after the digits, and there is
    /// none between "2" and "n". So ordinals reached the phonemizer as raw
    /// digits, which is exactly the input Misaki's incomplete number table
    /// mishandles or drops.
    private static func expandOrdinals(in text: String) -> String {
        replace(
            pattern: "\\b(\\d+)(?:st|nd|rd|th)\\b",
            in: text,
            caseInsensitive: true
        ) { groups in
            Int(groups[1]).map(ordinal) ?? groups[0]
        }
    }

    /// Ordinal words, derived from the cardinal so the full Int range works:
    /// only the FINAL word changes ("one hundred twenty-two" -> "...twenty-second").
    static func ordinal(_ number: Int) -> String {
        if number < 0 { return "minus " + ordinal(-number) }
        let words = cardinal(number)
        // The trailing word may follow a space or a hyphen ("twenty-two").
        guard let separator = words.lastIndex(where: { $0 == " " || $0 == "-" }) else {
            return ordinalWords[words] ?? words + "th"
        }
        let head = String(words[...separator])
        let tail = String(words[words.index(after: separator)...])
        return head + (ordinalWords[tail] ?? tail + "th")
    }

    private static let ordinalWords: [String: String] = [
        "zero": "zeroth", "one": "first", "two": "second", "three": "third",
        "four": "fourth", "five": "fifth", "six": "sixth", "seven": "seventh",
        "eight": "eighth", "nine": "ninth", "ten": "tenth", "eleven": "eleventh",
        "twelve": "twelfth", "thirteen": "thirteenth", "fourteen": "fourteenth",
        "fifteen": "fifteenth", "sixteen": "sixteenth", "seventeen": "seventeenth",
        "eighteen": "eighteenth", "nineteen": "nineteenth", "twenty": "twentieth",
        "thirty": "thirtieth", "forty": "fortieth", "fifty": "fiftieth",
        "sixty": "sixtieth", "seventy": "seventieth", "eighty": "eightieth",
        "ninety": "ninetieth", "hundred": "hundredth", "thousand": "thousandth",
        "million": "millionth", "billion": "billionth", "trillion": "trillionth",
    ]

    // MARK: - Slash

    private static func expandSlash(in text: String) -> String {
        // A "/" between two word/number characters reads as "slash" (and/or,
        // km/h, 12/25). Rate abbreviations were already consumed above, and bare
        // URLs were turned into "link" earlier, so this only hits real content.
        replace(pattern: "(?<=[\\p{L}\\p{N}])/(?=[\\p{L}\\p{N}])", in: text) { _ in " slash " }
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
