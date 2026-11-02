import Foundation

/// Finds a headword (including inflected forms and phrase patterns) inside an
/// example sentence and replaces it with a blank.
///
/// Returns nil when the sentence does not actually contain the word — callers
/// must then fall back to another question type instead of inventing a sentence.
enum ContextBlanker {
    static let blank = "______"

    static func blanked(_ word: String, in sentence: String) -> String? {
        guard let regex = regex(for: word) else { return nil }
        let nsSentence = sentence as NSString
        let matches = regex.matches(in: sentence, range: NSRange(location: 0, length: nsSentence.length))
        guard !matches.isEmpty else { return nil }

        // Replace every literal segment (capture group) from the end so earlier
        // ranges stay valid. Gaps such as the object in "take ~ back" stay visible.
        var ranges: [NSRange] = []
        for match in matches {
            for group in 1..<match.numberOfRanges {
                let range = match.range(at: group)
                if range.location != NSNotFound && range.length > 0 {
                    ranges.append(range)
                }
            }
        }
        let result = NSMutableString(string: sentence)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            result.replaceCharacters(in: range, with: blank)
        }
        return result as String
    }

    static func contains(_ word: String, in sentence: String) -> Bool {
        guard let regex = regex(for: word) else { return false }
        let range = NSRange(location: 0, length: (sentence as NSString).length)
        return regex.firstMatch(in: sentence, range: range) != nil
    }

    // MARK: - Pattern construction

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static let apostrophe = "['’]"
    private static let gap = "(?:\\s+[\\w'’,\\-]+){1,4}\\s+"
    private static let possessive = "(?:my|your|his|her|its|our|their|one['’]s|someone['’]s|[A-Za-z]+['’]s)"
    private static let reflexive = "(?:myself|yourself|himself|herself|itself|ourselves|yourselves|themselves|oneself)"
    private static let placeholders: Set<String> = ["~", "someone", "somebody", "something", "sb", "sth", "a person"]

    private static func regex(for word: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[word] { return cached }

        var tokens = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        // "be saddled with" → "I'm saddled with": the copula changes form and
        // often fuses with the subject, so match the rest of the phrase.
        if tokens.count > 1, tokens[0].lowercased() == "be" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }

        // Group literal tokens into runs separated by placeholder gaps.
        var runs: [[String]] = [[]]
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            let isPlaceholder = placeholders.contains(lower)
                || (token.count == 1 && token.uppercased() == token && token != "I" && tokens.count > 1)
            if isPlaceholder {
                if !(runs.last?.isEmpty ?? true) { runs.append([]) }
                continue
            }
            runs[runs.count - 1].append(tokenPattern(token, isHead: index == 0))
        }
        runs = runs.filter { !$0.isEmpty }
        guard !runs.isEmpty else { return nil }

        let body = runs
            .map { "(" + $0.joined(separator: "\\s+") + ")" }
            .joined(separator: gap)
        let pattern = "(?<![\\w'’])" + body + "(?![\\w])"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        cache[word] = regex
        return regex
    }

    private static func tokenPattern(_ token: String, isHead: Bool) -> String {
        let lower = token.lowercased()
        if lower.range(of: "^one['’]s$", options: .regularExpression) != nil { return possessive }
        if lower == "oneself" { return reflexive }
        guard isHead else { return escaped(lower) }
        let forms = inflections(of: lower).sorted { $0.count > $1.count }
        return "(?:" + forms.map(escaped).joined(separator: "|") + ")"
    }

    private static func escaped(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
            .replacingOccurrences(of: "'", with: apostrophe)
            .replacingOccurrences(of: "’", with: apostrophe)
    }

    /// Regular inflections plus the irregular verbs that appear in the word list.
    static func inflections(of word: String) -> Set<String> {
        var forms: Set<String> = [word, word + "s", word + "es", word + "ed", word + "d", word + "ing"]
        if word.hasSuffix("e") {
            let stem = String(word.dropLast())
            forms.formUnion([stem + "ing", stem + "ed"])
        }
        if word.hasSuffix("y") {
            let stem = String(word.dropLast())
            forms.formUnion([stem + "ies", stem + "ied"])
        }
        if word.range(of: "[^aeiou][aeiou][bdgklmnprt]$", options: .regularExpression) != nil, let last = word.last {
            forms.formUnion([word + String(last) + "ed", word + String(last) + "ing"])
        }
        if word.hasSuffix("ic") {
            forms.formUnion([word + "ked", word + "king"])
        }
        if let irregular = irregularForms[word] {
            forms.formUnion(irregular)
        }
        return forms
    }

    private static let irregularForms: [String: [String]] = [
        "begin": ["began", "begun"], "come": ["came"], "go": ["went", "gone"],
        "take": ["took", "taken"], "give": ["gave", "given"], "get": ["got", "gotten"],
        "run": ["ran"], "make": ["made"], "bring": ["brought"], "hold": ["held"],
        "keep": ["kept"], "break": ["broke", "broken"], "fall": ["fell", "fallen"],
        "draw": ["drew", "drawn"], "see": ["saw", "seen"], "stand": ["stood"],
        "lay": ["laid"], "pay": ["paid"], "say": ["said"], "think": ["thought"],
        "buy": ["bought"], "catch": ["caught"], "teach": ["taught"], "seek": ["sought"],
        "fight": ["fought"], "find": ["found"], "leave": ["left"], "lose": ["lost"],
        "mean": ["meant"], "meet": ["met"], "send": ["sent"], "spend": ["spent"],
        "build": ["built"], "feel": ["felt"], "sell": ["sold"], "tell": ["told"],
        "win": ["won"], "write": ["wrote", "written"], "drive": ["drove", "driven"],
        "rise": ["rose", "risen"], "arise": ["arose", "arisen"], "speak": ["spoke", "spoken"],
        "choose": ["chose", "chosen"], "forget": ["forgot", "forgotten"],
        "undergo": ["underwent", "undergone"], "withdraw": ["withdrew", "withdrawn"],
        "overcome": ["overcame"], "foresee": ["foresaw", "foreseen"], "withhold": ["withheld"],
        "uphold": ["upheld"], "undertake": ["undertook", "undertaken"], "mislead": ["misled"],
        "lead": ["led"], "bear": ["bore", "borne"], "shake": ["shook", "shaken"],
        "strike": ["struck"], "stick": ["stuck"], "hang": ["hung"], "sink": ["sank", "sunk"],
        "shrink": ["shrank", "shrunk"], "blow": ["blew", "blown"], "grow": ["grew", "grown"],
        "throw": ["threw", "thrown"], "fly": ["flew", "flown"], "lie": ["lay", "lain", "lying"],
        "have": ["has", "had"], "do": ["did", "done", "does"], "undo": ["undid", "undone"],
        "sit": ["sat"], "shoot": ["shot"], "hide": ["hid", "hidden"], "ride": ["rode", "ridden"],
        "sweep": ["swept"], "deal": ["dealt"], "flee": ["fled"], "know": ["knew", "known"],
        "oversee": ["oversaw", "overseen"], "overthrow": ["overthrew", "overthrown"],
        "forgo": ["forwent", "forgone"], "forsake": ["forsook", "forsaken"],
        "befall": ["befell", "befallen"], "steal": ["stole", "stolen"], "strew": ["strewn"],
        "tie": ["tying"], "die": ["dying"], "bark": ["barked"], "put": ["put"], "set": ["set"],
        "cut": ["cut"], "let": ["let"], "cast": ["cast"], "spread": ["spread"], "shed": ["shed"],
    ]
}
