import Foundation

/// Turns a corpus example sentence into a TEPS-style cloze item by replacing
/// the target word with a blank.
///
/// The corpus stores head words ("commute", "pick up", "take ~ back") but the
/// sentences use inflected forms ("commuting", "picked up", "took it back"), so
/// a plain `replacingOccurrences` misses roughly one sentence in ten and leaks
/// the answer. Matching is token based: the sentence is split into word tokens
/// and the target is matched as a small pattern over them.
///
/// Nothing is ever invented — if the target cannot be located in its own
/// example sentence the builder returns `nil` and the caller falls back to a
/// meaning question.
enum ContextSentenceBuilder {

    static let placeholder = "______"

    // MARK: - Public API

    /// Sentence with the target word replaced by `placeholder`, or nil when the
    /// target does not appear in the sentence in any recognised form.
    static func blankedSentence(sentence: String?, target: String, placeholder: String = ContextSentenceBuilder.placeholder) -> String? {
        guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return nil }
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return nil }

        let characters = Array(sentence)
        let tokens = tokenize(characters)
        guard !tokens.isEmpty else { return nil }

        let pattern = makePattern(for: trimmedTarget)
        guard !pattern.isEmpty else { return nil }
        let matches = allMatches(pattern: pattern, tokens: tokens)
        guard !matches.isEmpty else { return nil }

        // Every occurrence is blanked, not just the first: some corpus
        // sentences mention the word twice ("The primary objective … an
        // objective analysis"), and leaving the second one visible would hand
        // the answer to the learner.
        var result = ""
        var cursor = 0
        var previousWasBlank = false
        for match in matches {
            let gap = match.startOffset > cursor ? String(characters[cursor..<match.startOffset]) : ""
            if previousWasBlank && !gap.contains(where: { $0.isLetter }) {
                // A handful of generated sentences repeat the phrase back to
                // back ("… effort to stave off stave off an imminent …").
                // Collapse those into a single blank instead of a row of them.
                cursor = match.endOffset
                continue
            }
            result += gap
            result += placeholder
            cursor = match.endOffset
            previousWasBlank = true
        }
        if cursor < characters.count {
            result += String(characters[cursor...])
        }
        return result
    }

    /// Same as `blankedSentence` but never fails: when the target cannot be
    /// located the original sentence is returned unchanged. Used where hiding
    /// the word is a nicety rather than the point of the question.
    static func maskedSentence(sentence: String?, target: String, placeholder: String = ContextSentenceBuilder.placeholder) -> String? {
        guard let sentence = sentence, !sentence.isEmpty else { return nil }
        return blankedSentence(sentence: sentence, target: target, placeholder: placeholder) ?? sentence
    }

    /// True when `candidate` (a distractor) already appears in the sentence —
    /// such an option would be a give-away and must not be offered.
    static func sentenceContains(_ candidate: String, sentence: String) -> Bool {
        blankedSentence(sentence: sentence, target: candidate) != nil
    }

    // MARK: - Tokenizing

    private struct Token {
        let text: String      // lowercased, apostrophes normalised
        let startOffset: Int  // index into the character array
        let endOffset: Int    // exclusive
    }

    private struct MatchRange {
        let startOffset: Int
        let endOffset: Int
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    private static func tokenize(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            guard isWordCharacter(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count && isWordCharacter(characters[index]) {
                index += 1
            }
            let raw = String(characters[start..<index])
            // A trailing apostrophe (possessive "students'") is punctuation.
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}"))
            if !cleaned.isEmpty {
                tokens.append(Token(text: normalize(cleaned), startOffset: start, endOffset: index))
            }
        }
        return tokens
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    // MARK: - Pattern

    private enum PatternElement {
        /// Any of these surface forms matches one token.
        case word(Set<String>)
        /// A placeholder slot ("~", "one's", "oneself", "sb") — 0 to 3 tokens.
        case wildcard(minTokens: Int, maxTokens: Int)
    }

    /// Placeholder-ish tokens used by the corpus for phrasal entries.
    private static let placeholderTokens: Set<String> = [
        "~", "one's", "ones", "oneself", "someone", "somebody", "something",
        "sb", "sth", "one"
    ]

    private static func makePattern(for target: String) -> [PatternElement] {
        let normalized = normalize(target)
        let rawTokens = normalized
            .replacingOccurrences(of: "~", with: " ~ ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        let allowedScalars = CharacterSet.letters.union(CharacterSet(charactersIn: "'~"))
        var elements: [PatternElement] = []
        for rawToken in rawTokens {
            // Drop punctuation the corpus sometimes carries ("pull one's leg.")
            let token = String(String.UnicodeScalarView(rawToken.unicodeScalars.filter { allowedScalars.contains($0) }))
            if token.isEmpty { continue }
            if placeholderTokens.contains(token) {
                elements.append(.wildcard(minTokens: 0, maxTokens: 3))
            } else {
                elements.append(.word(EnglishInflector.surfaceForms(of: token)))
            }
        }

        // A pattern that is only wildcards can match anything — refuse it.
        let hasWord = elements.contains { element in
            if case .word = element { return true }
            return false
        }
        return hasWord ? elements : []
    }

    // MARK: - Matching

    private static func allMatches(pattern: [PatternElement], tokens: [Token]) -> [MatchRange] {
        var ranges: [MatchRange] = []
        var start = 0
        while start < tokens.count {
            if let end = match(pattern: pattern, patternIndex: 0, tokens: tokens, tokenIndex: start), end > start {
                // `end` is exclusive in token space and always covers a real
                // word, never a trailing wildcard that consumed nothing.
                ranges.append(MatchRange(startOffset: tokens[start].startOffset, endOffset: tokens[end - 1].endOffset))
                start = end
            } else {
                start += 1
            }
        }
        return ranges
    }

    /// Returns the exclusive token index the pattern ends at, or nil.
    private static func match(pattern: [PatternElement], patternIndex: Int, tokens: [Token], tokenIndex: Int) -> Int? {
        if patternIndex >= pattern.count { return tokenIndex }
        guard tokenIndex <= tokens.count else { return nil }

        switch pattern[patternIndex] {
        case .word(let forms):
            guard tokenIndex < tokens.count, forms.contains(tokens[tokenIndex].text) else { return nil }
            return match(pattern: pattern, patternIndex: patternIndex + 1, tokens: tokens, tokenIndex: tokenIndex + 1)
        case .wildcard(let minTokens, let maxTokens):
            var consumed = minTokens
            while consumed <= maxTokens {
                let next = tokenIndex + consumed
                if next > tokens.count { break }
                if let end = match(pattern: pattern, patternIndex: patternIndex + 1, tokens: tokens, tokenIndex: next) {
                    return end
                }
                consumed += 1
            }
            return nil
        }
    }
}

/// Generates the surface forms an English head word can take in a sentence.
/// Deliberately conservative: it only produces regular inflections plus a small
/// table of very common irregulars, so it never claims a match it cannot back up.
enum EnglishInflector {

    private static let irregulars: [String: Set<String>] = [
        "be": ["am", "is", "are", "was", "were", "been", "being"],
        "have": ["has", "had", "having"],
        "do": ["does", "did", "done", "doing"],
        "go": ["goes", "went", "gone", "going"],
        "get": ["gets", "got", "gotten", "getting"],
        "take": ["takes", "took", "taken", "taking"],
        "make": ["makes", "made", "making"],
        "give": ["gives", "gave", "given", "giving"],
        "come": ["comes", "came", "coming"],
        "see": ["sees", "saw", "seen", "seeing"],
        "know": ["knows", "knew", "known", "knowing"],
        "think": ["thinks", "thought", "thinking"],
        "say": ["says", "said", "saying"],
        "put": ["puts", "putting"],
        "keep": ["keeps", "kept", "keeping"],
        "hold": ["holds", "held", "holding"],
        "run": ["runs", "ran", "running"],
        "bring": ["brings", "brought", "bringing"],
        "stand": ["stands", "stood", "standing"],
        "fall": ["falls", "fell", "fallen", "falling"],
        "break": ["breaks", "broke", "broken", "breaking"],
        "leave": ["leaves", "left", "leaving"],
        "lose": ["loses", "lost", "losing"],
        "pay": ["pays", "paid", "paying"],
        "draw": ["draws", "drew", "drawn", "drawing"],
        "blow": ["blows", "blew", "blown", "blowing"],
        "wear": ["wears", "wore", "worn", "wearing"],
        "sit": ["sits", "sat", "sitting"],
        "speak": ["speaks", "spoke", "spoken", "speaking"],
        "write": ["writes", "wrote", "written", "writing"],
        "cut": ["cuts", "cutting"],
        "let": ["lets", "letting"],
        "set": ["sets", "setting"],
        "catch": ["catches", "caught", "catching"],
        "feel": ["feels", "felt", "feeling"],
        "find": ["finds", "found", "finding"],
        "tell": ["tells", "told", "telling"],
        "man": ["men"],
        "woman": ["women"],
        "child": ["children"],
        "person": ["people"],
        "foot": ["feet"],
        "tooth": ["teeth"]
    ]

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// All spellings of `word` that should count as an occurrence of it.
    static func surfaceForms(of word: String) -> Set<String> {
        let base = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var forms: Set<String> = [base]
        guard base.count >= 2, base.allSatisfy({ $0.isLetter || $0 == "'" }) else { return forms }

        if let known = irregulars[base] {
            forms.formUnion(known)
        }

        let characters = Array(base)
        let last = characters[characters.count - 1]
        let secondLast: Character? = characters.count >= 2 ? characters[characters.count - 2] : nil
        let stem = String(characters.dropLast())

        // -s / -es (third person, plural)
        if base.hasSuffix("s") || base.hasSuffix("x") || base.hasSuffix("z") ||
            base.hasSuffix("ch") || base.hasSuffix("sh") || base.hasSuffix("o") {
            forms.insert(base + "es")
        } else if last == "y", let previous = secondLast, !vowels.contains(previous) {
            forms.insert(stem + "ies")
        } else {
            forms.insert(base + "s")
        }

        // -ed / -ing
        if last == "e" {
            forms.insert(base + "d")
            forms.insert(stem + "ing")
            forms.insert(base + "s")
        } else if last == "y", let previous = secondLast, !vowels.contains(previous) {
            forms.insert(stem + "ied")
            forms.insert(base + "ing")
        } else {
            forms.insert(base + "ed")
            forms.insert(base + "ing")
            if base.hasSuffix("c") {
                forms.insert(base + "ked")
                forms.insert(base + "king")
            }
            // CVC words double the final consonant: "plan" → "planned".
            if characters.count >= 3,
               let previous = secondLast,
               vowels.contains(previous),
               !vowels.contains(last),
               !"wxy".contains(last),
               !vowels.contains(characters[characters.count - 3]) {
                forms.insert(base + String(last) + "ed")
                forms.insert(base + String(last) + "ing")
            }
        }

        // Nouns/adjectives ending in -is → -es ("analysis" → "analyses")
        if base.hasSuffix("is") {
            forms.insert(String(characters.dropLast(2)) + "es")
        }

        return forms
    }
}
