import Foundation

enum PartOfSpeech: String {
    case verb, noun, adjective, adverb
}

/// Features derived only from data that already exists in Corpus
/// (the `pos`/`synonym` columns are empty in the bundled DB, so part of speech
/// is read from the Korean gloss ending: ~하다 → verb, ~한/~적인 → adjective, …).
struct WordFeatures {
    let corpus: Corpus
    let pos: PartOfSpeech
    let categories: Set<String>
    /// Korean meaning stems ("비난하다" → "비난") used for semantic closeness.
    let meaningStems: Set<String>
    let primaryMeaning: String
    let tokenCount: Int

    init(corpus: Corpus) {
        self.corpus = corpus
        let variants = WordFeatures.meaningVariants(corpus.meaning)
        let primary = WordFeatures.core(variants.first ?? corpus.meaning)
        self.primaryMeaning = primary
        self.pos = WordFeatures.inferPartOfSpeech(primary)
        self.categories = WordFeatures.categories(from: corpus.desc)
        self.meaningStems = Set(variants.flatMap(WordFeatures.stems))
        self.tokenCount = corpus.word.split(whereSeparator: { $0.isWhitespace }).count
    }

    // MARK: Derivation helpers

    static func meaningVariants(_ meaning: String) -> [String] {
        var variants: [String] = []
        var current = ""
        var depth = 0
        for ch in meaning {
            if ch == "(" || ch == "（" { depth += 1 }
            else if ch == ")" || ch == "）" { depth = max(0, depth - 1) }
            if ch == "﹒" && depth == 0 {
                variants.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        variants.append(current)
        return variants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Strips parenthesised notes and alternatives: "(공개적으로) 맹렬히 비난하다; 혹평" → "맹렬히 비난하다".
    static func core(_ variant: String) -> String {
        let noParens = variant.replacingOccurrences(of: "[\\(（][^\\)）]*[\\)）]", with: "", options: .regularExpression)
        let first = noParens.split(whereSeparator: { $0 == ";" || $0 == "," }).first.map(String.init) ?? noParens
        return first.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func inferPartOfSpeech(_ gloss: String) -> PartOfSpeech {
        guard let last = gloss.last else { return .noun }
        if last == "다" { return .verb }
        if gloss.count >= 2 && (last == "히" || last == "게") { return .adverb }
        // "~에 관계없이", "의도적으로", "~에도 불구하고": adverbial glosses
        let adverbialEndings = ["없이", "같이", "으로", "불구하고", "하여"]
        if gloss.count >= 3 && adverbialEndings.contains(where: gloss.hasSuffix) { return .adverb }
        let adjectiveEndings = ["하는", "되는", "있는", "없는", "적인", "스러운", "로운", "러운", "같은", "않은", "해진", "어진", "아진"]
        if adjectiveEndings.contains(where: gloss.hasSuffix) { return .adjective }
        let nounsEndingLikeAdjectives = ["권한", "제한", "기한", "시한", "주인", "원인", "개인", "부인", "요인", "증인", "상인", "군인", "노인", "죄인", "시인", "행운", "기운"]
        if nounsEndingLikeAdjectives.contains(where: gloss.hasSuffix) { return .noun }
        if gloss.count >= 2 && "한인운는은된던의".contains(last) { return .adjective }
        return .noun
    }

    static func categories(from desc: String?) -> Set<String> {
        guard let desc, let range = desc.range(of: "Category:") else { return [] }
        let tail = desc[range.upperBound...]
        let field = tail.split(separator: "|").first.map(String.init) ?? ""
        return Set(field.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "general" })
    }

    private static let stemSuffixes = ["시키다", "스러운", "하다", "되다", "하는", "되는", "적인", "적으로", "하게", "히", "한", "된", "인", "다"]
    private static let stopStems: Set<String> = ["것", "수", "등", "일", "하", "되", "있", "없", "같", "사람"]

    static func stems(_ variant: String) -> [String] {
        let text = core(variant)
        return text.split(whereSeparator: { $0 == " " || $0 == "·" || $0 == "/" }).compactMap { raw in
            var token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "~-=…"))
            for suffix in stemSuffixes where token.count > suffix.count && token.hasSuffix(suffix) {
                token = String(token.dropLast(suffix.count))
                break
            }
            return token.count >= 2 && !stopStems.contains(token) ? token : nil
        }
    }
}

/// Chooses wrong options. Context questions prefer plausible competitors
/// (same part of speech → related meaning → same category → similar form),
/// with spelling similarity and randomness only as fallbacks.
final class DistractorService {
    private let features: [WordFeatures]
    private let byId: [String: WordFeatures]

    init(pool: [Corpus]) {
        let features = pool.map(WordFeatures.init)
        self.features = features
        self.byId = Dictionary(features.map { ($0.corpus.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func features(for corpus: Corpus) -> WordFeatures {
        byId[corpus.id] ?? WordFeatures(corpus: corpus)
    }

    // MARK: Meaning questions (choose the Korean meaning)

    /// Same-POS meanings so the answer cannot be picked from the gloss's
    /// grammatical form alone; one spelling-confusable word keeps the original
    /// "look-alike" training; near-synonym glosses are excluded to avoid two correct options.
    func meaningDistractors(for target: Corpus, count: Int) -> [Corpus] {
        let t = features(for: target)
        var pool = candidates(for: t) { $0.pos == t.pos }
        if pool.count < count { pool = candidates(for: t) { _ in true } }

        var chosen: [WordFeatures] = []
        if let lookalike = pool
            .shuffled().prefix(80)
            .min(by: { spellingDistance(t, $0) < spellingDistance(t, $1) }) {
            chosen.append(lookalike)
        }
        let sameCategory = pool.filter { !t.categories.isEmpty && !$0.categories.isDisjoint(with: t.categories) }
        if let categoryPick = sameCategory.shuffled().first(where: { c in !chosen.contains { $0.corpus.id == c.corpus.id } }) {
            chosen.append(categoryPick)
        }
        fill(&chosen, from: pool.shuffled(), target: t, count: count)
        return chosen.prefix(count).map(\.corpus)
    }

    // MARK: Context questions (choose the English word for the blank)

    func contextDistractors(for target: Corpus, blankedSentence: String, count: Int) -> [Corpus] {
        let t = features(for: target)
        let isPhrase = t.tokenCount > 1
        // Options must share the target's shape (single word vs phrase) — otherwise
        // the odd one out is guessable without reading the sentence.
        let sameShape: (WordFeatures) -> Bool = { ($0.tokenCount > 1) == isPhrase }
        // A word already present elsewhere in the sentence would be a giveaway.
        // Cheap substring check first; the regex only runs for plausible hits.
        let lowerSentence = blankedSentence.lowercased()
        let notInSentence: (WordFeatures) -> Bool = { c in
            let head = c.corpus.word.lowercased().split(separator: " ").first.map { String($0.prefix(4)) } ?? ""
            return !lowerSentence.contains(head) || !ContextBlanker.contains(c.corpus.word, in: blankedSentence)
        }

        var pool = candidates(for: t) { sameShape($0) && $0.pos == t.pos && notInSentence($0) }
        if pool.count < count { pool = candidates(for: t) { sameShape($0) && notInSentence($0) } }
        if pool.count < count { pool = candidates(for: t) { notInSentence($0) } }

        var chosen: [WordFeatures] = []

        // 1. One semantic competitor: related meaning, but not a near-synonym
        //    (a true synonym would make the question ambiguous).
        let related = pool
            .map { ($0, $0.meaningStems.intersection(t.meaningStems).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map(\.0)
        if let pick = related.shuffled().first { chosen.append(pick) }

        // 2. One from the same subject category (Business, Legal, …) when known.
        let sameCategory = pool.filter { !t.categories.isEmpty && !$0.categories.isDisjoint(with: t.categories) }
        if let pick = sameCategory.shuffled().first(where: { c in !chosen.contains { $0.corpus.id == c.corpus.id } }) {
            chosen.append(pick)
        }

        // 3. Phrases: prefer ones built on the same frame ("regardless of" ↔
        //    "in spite of", "take action" ↔ "take notes"), which read as grammatical
        //    in the blank and must be told apart by meaning.
        if isPhrase {
            let frame = phraseFrame(target.word)
            let sameFrame = pool.filter { c in
                let other = phraseFrame(c.corpus.word)
                return (frame.first != nil && other.first == frame.first) || (frame.last != nil && other.last == frame.last)
            }
            var added = 0
            for pick in sameFrame.shuffled() where chosen.count < count && added < 2 {
                if !chosen.contains(where: { $0.corpus.id == pick.corpus.id || isNearDuplicate($0, pick) }) {
                    chosen.append(pick)
                    added += 1
                }
            }
        }

        // 4. Fill with same-POS words, nudged toward similar length/form, then random.
        let ranked = pool.shuffled().prefix(120).sorted {
            formScore(t, $0) < formScore(t, $1)
        }
        fill(&chosen, from: Array(ranked.prefix(12)).shuffled() + pool.shuffled(), target: t, count: count)
        return chosen.prefix(count).map(\.corpus)
    }

    // MARK: Shared helpers

    private func candidates(for target: WordFeatures, where predicate: (WordFeatures) -> Bool) -> [WordFeatures] {
        features.filter { c in
            c.corpus.id != target.corpus.id
                && !c.corpus.meaning.isEmpty
                && !isNearDuplicate(target, c)
                && predicate(c)
        }
    }

    /// Same headword/lemma or practically the same gloss → would be a second correct answer.
    private func isNearDuplicate(_ a: WordFeatures, _ b: WordFeatures) -> Bool {
        let wa = a.corpus.word.lowercased(), wb = b.corpus.word.lowercased()
        if wa == wb || wa.hasPrefix(wb + " ") || wb.hasPrefix(wa + " ") { return true }
        if !a.primaryMeaning.isEmpty && a.primaryMeaning == b.primaryMeaning { return true }
        let union = a.meaningStems.union(b.meaningStems).count
        guard union > 0 else { return false }
        let jaccard = Double(a.meaningStems.intersection(b.meaningStems).count) / Double(union)
        return jaccard >= 0.5
    }

    private func fill(_ chosen: inout [WordFeatures], from source: [WordFeatures], target: WordFeatures, count: Int) {
        for candidate in source where chosen.count < count {
            let duplicate = chosen.contains {
                $0.corpus.id == candidate.corpus.id || isNearDuplicate($0, candidate)
            }
            if !duplicate { chosen.append(candidate) }
        }
    }

    private static let frameWords: Set<String> = [
        "of", "to", "on", "in", "with", "up", "out", "off", "for", "at", "down", "over", "away", "back", "into", "about",
        "take", "make", "give", "get", "put", "come", "go", "run", "keep", "bring", "turn", "set", "break", "hold", "pull", "play",
    ]

    /// Leading verb / trailing particle of a phrase, when they are common frame words.
    private func phraseFrame(_ word: String) -> (first: String?, last: String?) {
        let tokens = word.lowercased().split(separator: " ").map(String.init).filter { $0 != "~" }
        guard tokens.count > 1 else { return (nil, nil) }
        let first = tokens.first.flatMap { Self.frameWords.contains($0) ? $0 : nil }
        let last = tokens.last.flatMap { Self.frameWords.contains($0) ? $0 : nil }
        return (first, last)
    }

    private func formScore(_ target: WordFeatures, _ candidate: WordFeatures) -> Int {
        abs(target.corpus.word.count - candidate.corpus.word.count)
    }

    private func spellingDistance(_ a: WordFeatures, _ b: WordFeatures) -> Int {
        levenshtein(a.corpus.word.lowercased(), b.corpus.word.lowercased())
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var last = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? last[j - 1] : min(last[j - 1], last[j], current[j - 1]) + 1
            }
            last = current
        }
        return last[b.count]
    }
}
