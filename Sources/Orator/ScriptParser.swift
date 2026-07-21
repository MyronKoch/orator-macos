import Foundation

enum ScriptElement: Equatable, Sendable {
    case characterCue(String)
    case dialogue(String)
    case action(String)
    case sceneHeading(String)
    case parenthetical(String)
    case transition(String)
}

/// Parses the deterministic subset shared by Fountain and simple `NAME:` scripts.
enum ScriptParser {
    static func parse(_ text: String) -> [ScriptElement] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var elements: [ScriptElement] = []
        var currentCharacter: String?
        var pendingDialogue: [String] = []
        var pendingAction: [String] = []

        func flushDialogue() {
            guard !pendingDialogue.isEmpty else { return }
            elements.append(.dialogue(pendingDialogue.joined(separator: " ")))
            pendingDialogue.removeAll(keepingCapacity: true)
        }

        func flushAction() {
            guard !pendingAction.isEmpty else { return }
            elements.append(.action(pendingAction.joined(separator: " ")))
            pendingAction.removeAll(keepingCapacity: true)
        }

        func appendStructural(_ element: ScriptElement) {
            flushDialogue()
            flushAction()
            elements.append(element)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushDialogue()
                flushAction()
                currentCharacter = nil
                continue
            }

            if isSceneHeading(line) {
                currentCharacter = nil
                appendStructural(.sceneHeading(line))
            } else if isTransition(line) {
                currentCharacter = nil
                appendStructural(.transition(normalizedTransition(line)))
            } else if isParenthetical(line) {
                flushDialogue()
                appendStructural(.parenthetical(line))
            } else if let namedLine = nameConvention(line) {
                currentCharacter = namedLine.name
                appendStructural(.characterCue(namedLine.name))
                if !namedLine.dialogue.isEmpty {
                    pendingDialogue.append(namedLine.dialogue)
                }
            } else if isCharacterCue(line) {
                let name = normalizedCharacterName(line)
                currentCharacter = name
                appendStructural(.characterCue(name))
            } else if currentCharacter != nil {
                flushAction()
                pendingDialogue.append(line)
            } else {
                flushDialogue()
                pendingAction.append(line)
            }
        }

        flushDialogue()
        flushAction()
        return elements
    }

    static func characterNames(in elements: [ScriptElement]) -> [String] {
        var seen = Set<String>()
        return elements.compactMap { element in
            guard case .characterCue(let name) = element, seen.insert(name).inserted else {
                return nil
            }
            return name
        }
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.uppercased()
        return upper.hasPrefix("INT.") || upper.hasPrefix("EXT.")
            || upper.hasPrefix("INT/") || upper.hasPrefix("EXT/")
            || upper.hasPrefix("I/E.")
    }

    private static func isTransition(_ line: String) -> Bool {
        let upper = line.uppercased()
        return line.hasPrefix(">") || upper.hasSuffix("TO:")
    }

    private static func normalizedTransition(_ line: String) -> String {
        line.hasPrefix(">")
            ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            : line
    }

    private static func isParenthetical(_ line: String) -> Bool {
        line.hasPrefix("(") && line.hasSuffix(")")
    }

    private static func nameConvention(_ line: String) -> (name: String, dialogue: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let prefix = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard isCharacterCue(prefix) else { return nil }
        let dialogue = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (normalizedCharacterName(prefix), dialogue)
    }

    private static func isCharacterCue(_ line: String) -> Bool {
        let candidate = line.trimmingCharacters(in: .whitespaces)
        guard candidate.rangeOfCharacter(from: .letters) != nil,
              candidate == candidate.uppercased(),
              !candidate.hasSuffix("."),
              !candidate.contains(":") else { return false }
        return true
    }

    /// Fountain extensions such as `RILEY (V.O.)` describe delivery, not a new cast member.
    private static func normalizedCharacterName(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let opening = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") else {
            return trimmed
        }
        let base = trimmed[..<opening].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? trimmed : base
    }
}
