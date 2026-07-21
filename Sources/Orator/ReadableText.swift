import Foundation

/// Removes visual formatting that would otherwise be spoken aloud by TTS.
enum ReadableText {

    /// Strip markdown STRUCTURE (code, links, lists, tables, emphasis, URLs).
    /// Symbol sanitizing is a SEPARATE pass (`sanitizeSymbols`) so text
    /// expansions (numbers, currency, user replacements) can run in between -
    /// they need to see the content symbols before those get dropped.
    static func markdownClean(_ text: String) -> String {
        var cleaned = replaceFencedCodeBlocks(in: text)
        cleaned = replaceMarkdownLinks(in: cleaned)
        cleaned = processBlockStructure(in: cleaned)
        cleaned = cleanInlineMarkup(in: cleaned)
        cleaned = replaceBareURLs(in: cleaned)
        return collapseParagraphBreaks(in: cleaned)
    }

    /// A handful of symbols that read naturally as a word between other words.
    private static let symbolWords: [Character: String] = [
        "&": " and ",
        "=": " equals ",
        "+": " plus ",
        "%": " percent ",
        "@": " at ",
        "\u{00D7}": " times ",       // ×
        "\u{00F7}": " divided by ",  // ÷
        "\u{00B0}": " degrees ",     // °
    ]

    /// Punctuation the phonemizer handles correctly (pauses, intonation,
    /// contractions, and the quotes Dramatize relies on) - kept as-is.
    private static let spokenPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":",
        "'", "\u{2019}", "\u{2018}",                       // ' ’ ‘
        "\"", "\u{201C}", "\u{201D}",                      // " “ ”
        "(", ")", "-", "\u{2013}", "\u{2014}", "\u{2026}", // - – — …
    ]

    /// Map the common symbols to words and drop every other non-alphanumeric
    /// glyph (arrows, bullets, math signs, box-drawing, emoji, …) to a space.
    /// Without this, the G2P voices an unknown glyph as a stray "x" (the /x/
    /// velar fricative it falls back to). Letters/numbers (incl. accented and
    /// non-Latin) and the spoken-punctuation set are preserved.
    static func sanitizeSymbols(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if let word = symbolWords[character] {
                output.append(word)
            } else if character.isLetter
                || character.isNumber
                || character.isWhitespace
                || spokenPunctuation.contains(character) {
                output.append(character)
            } else {
                output.append(" ")
            }
        }
        return output
    }

    private static func replaceFencedCodeBlocks(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            guard isFenceLine(lines[lineIndex]) else {
                output.append(lines[lineIndex])
                lineIndex += 1
                continue
            }

            var closingIndex = lineIndex + 1
            while closingIndex < lines.count && !isFenceLine(lines[closingIndex]) {
                closingIndex += 1
            }

            guard closingIndex < lines.count else {
                // An unmatched fence may just be prose containing backticks.
                output.append(lines[lineIndex])
                lineIndex += 1
                continue
            }

            output.append("(code block)")
            lineIndex = closingIndex + 1
        }

        return output.joined(separator: "\n")
    }

    private static func isFenceLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
    }

    private static func replaceMarkdownLinks(in text: String) -> String {
        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            let isImage = text[index] == "!"
                && !isEscaped(index, in: text)
                && text.index(after: index) < text.endIndex
                && text[text.index(after: index)] == "["

            let isLink: Bool
            if text[index] == "[" && !isEscaped(index, in: text) {
                if index > text.startIndex {
                    isLink = text[text.index(before: index)] != "!"
                } else {
                    isLink = true
                }
            } else {
                isLink = false
            }

            guard isImage || isLink else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            let labelStart = isImage ? text.index(index, offsetBy: 2) : text.index(after: index)
            let openingBracket = text.index(before: labelStart)

            guard let closingBracket = matchingDelimiter(
                in: text,
                after: openingBracket,
                opening: "[",
                closing: "]"
            ) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            let openingParenthesis = text.index(after: closingBracket)
            guard openingParenthesis < text.endIndex,
                  text[openingParenthesis] == "(",
                  let closingParenthesis = matchingDelimiter(
                      in: text,
                      after: openingParenthesis,
                      opening: "(",
                      closing: ")"
                  ) else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            output.append(contentsOf: text[labelStart..<closingBracket])
            index = text.index(after: closingParenthesis)
        }

        return output
    }

    private static func matchingDelimiter(
        in text: String,
        after openingIndex: String.Index,
        opening: Character,
        closing: Character
    ) -> String.Index? {
        var depth = 1
        var index = text.index(after: openingIndex)

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" {
                return nil
            }
            if !isEscaped(index, in: text) {
                if character == opening {
                    depth += 1
                } else if character == closing {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        var slashCount = 0
        var cursor = index

        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }

        return slashCount.isMultiple(of: 2) == false
    }

    private static func cleanInlineMarkup(in text: String) -> String {
        var output = ""
        var plainTextStart = text.startIndex
        var searchStart = text.startIndex

        while let opening = nextInlineCodeDelimiter(in: text, from: searchStart) {
            let contentStart = text.index(after: opening)
            guard let closing = nextInlineCodeDelimiter(
                in: text,
                from: contentStart,
                stopAtLineBreak: true
            ) else {
                searchStart = contentStart
                continue
            }

            output.append(contentsOf: cleanEmphasis(String(text[plainTextStart..<opening])))
            output.append(contentsOf: text[contentStart..<closing])
            plainTextStart = text.index(after: closing)
            searchStart = plainTextStart
        }

        output.append(contentsOf: cleanEmphasis(String(text[plainTextStart...])))
        return output
    }

    private static func nextInlineCodeDelimiter(
        in text: String,
        from start: String.Index,
        stopAtLineBreak: Bool = false
    ) -> String.Index? {
        var index = start

        while index < text.endIndex {
            if stopAtLineBreak && (text[index] == "\n" || text[index] == "\r") {
                return nil
            }
            if text[index] == "`" && !isEscaped(index, in: text) {
                let hasBacktickBefore = index > text.startIndex
                    && text[text.index(before: index)] == "`"
                let next = text.index(after: index)
                let hasBacktickAfter = next < text.endIndex && text[next] == "`"
                if !hasBacktickBefore && !hasBacktickAfter { return index }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private static func cleanEmphasis(_ text: String) -> String {
        var cleaned = text
        cleaned = replacingMatches(
            in: cleaned,
            pattern: #"(?<![\p{L}\p{N}*])\*\*(?=\S)(.+?)(?<=\S)\*\*(?![\p{L}\p{N}*])"#,
            with: "$1"
        )
        cleaned = replacingMatches(
            in: cleaned,
            pattern: #"(?<![\p{L}\p{N}*])\*(?=\S)(.+?)(?<=\S)\*(?![\p{L}\p{N}*])"#,
            with: "$1"
        )
        cleaned = replacingMatches(
            in: cleaned,
            pattern: #"(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])"#,
            with: "$1"
        )
        cleaned = replacingMatches(
            in: cleaned,
            pattern: #"(?<![\p{L}\p{N}_])_(?=\S)(.+?)(?<=\S)_(?![\p{L}\p{N}_])"#,
            with: "$1"
        )
        return replacingMatches(
            in: cleaned,
            pattern: #"(?<![\p{L}\p{N}~])~~(?=\S)(.+?)(?<=\S)~~(?![\p{L}\p{N}~])"#,
            with: "$1"
        )
    }

    private static func replaceBareURLs(in text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:https?://|www\.)[^\s<>*~`]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            output.append(contentsOf: text[cursor..<range.lowerBound])
            let (url, trailingPunctuation) = splitTrailingPunctuation(
                from: String(text[range])
            )
            output.append(contentsOf: url.isEmpty ? String(text[range]) : "link")
            output.append(contentsOf: trailingPunctuation)
            cursor = range.upperBound
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    private static func splitTrailingPunctuation(from candidate: String) -> (String, String) {
        var url = candidate
        var suffix = ""

        while let last = url.last {
            let isSentencePunctuation = ".,!?;:".contains(last)
            let isUnmatchedClosingDelimiter: Bool
            switch last {
            case ")":
                isUnmatchedClosingDelimiter = url.filter { $0 == ")" }.count
                    > url.filter { $0 == "(" }.count
            case "]":
                isUnmatchedClosingDelimiter = url.filter { $0 == "]" }.count
                    > url.filter { $0 == "[" }.count
            case "}":
                isUnmatchedClosingDelimiter = url.filter { $0 == "}" }.count
                    > url.filter { $0 == "{" }.count
            default:
                isUnmatchedClosingDelimiter = false
            }

            guard isSentencePunctuation || isUnmatchedClosingDelimiter else { break }
            url.removeLast()
            suffix.insert(last, at: suffix.startIndex)
        }

        return (url, suffix)
    }

    private static func processBlockStructure(in text: String) -> String {
        text.components(separatedBy: "\n")
            .map(processLine)
            .joined(separator: "\n")
    }

    private static func processLine(_ originalLine: String) -> String {
        var line = originalLine
        var candidate = trimmingLeadingWhitespace(from: line)

        var removedBlockquote = false
        while candidate.first == ">" {
            removedBlockquote = true
            candidate.removeFirst()
            candidate = trimmingLeadingWhitespace(from: candidate)
        }
        if removedBlockquote { line = candidate }

        candidate = trimmingLeadingWhitespace(from: line)
        if isHorizontalRule(candidate) { return "" }
        if isTableSeparatorRow(candidate) { return "" }

        if candidate.first == "#" {
            let title = candidate.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
            return ensuringPause(after: String(title))
        }

        if let item = listItemContent(in: candidate) {
            return ensuringPause(after: item)
        }

        if line.contains("|") {
            return spokenTableRow(line)
        }

        return line
    }

    private static func trimmingLeadingWhitespace(from text: String) -> String {
        String(text.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func listItemContent(in line: String) -> String? {
        guard let first = line.first else { return nil }
        let afterFirst = line.index(after: line.startIndex)

        if first == "-" || first == "*" || first == "+" {
            guard afterFirst == line.endIndex || line[afterFirst].isWhitespace else {
                return nil
            }
            return trimmingLeadingWhitespace(from: String(line[afterFirst...]))
        }

        var cursor = line.startIndex
        while cursor < line.endIndex && line[cursor].isNumber {
            cursor = line.index(after: cursor)
        }
        guard cursor > line.startIndex, cursor < line.endIndex, line[cursor] == "." else {
            return nil
        }

        let afterPeriod = line.index(after: cursor)
        guard afterPeriod == line.endIndex || line[afterPeriod].isWhitespace else {
            return nil
        }
        return trimmingLeadingWhitespace(from: String(line[afterPeriod...]))
    }

    private static func ensuringPause(after text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        if last == "." || last == "!" || last == "?" || last == ";" {
            return trimmed
        }
        return trimmed + "."
    }

    private static func isTableSeparatorRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cells.isEmpty else { return false }

        return cells.allSatisfy { cell in
            let withoutColons = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutColons.count >= 3 && withoutColons.allSatisfy { $0 == "-" }
        }
    }

    private static func spokenTableRow(_ line: String) -> String {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.joined(separator: ", ")
    }

    private static func collapseParagraphBreaks(in text: String) -> String {
        replacingMatches(in: text, pattern: #"(?:\r?\n){3,}"#, with: "\n\n")
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement
        )
    }
}
