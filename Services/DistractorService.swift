import Foundation

/// One wrong answer offered next to the correct one.
struct Distractor: Hashable {
    let id: String
    let word: String
    let meaning: String
}

/// Picks the three wrong options for a question.
///
/// The original app ranked candidates purely by Levenshtein distance, which
/// produces spelling look-alikes ("adapt / adopt"). TEPS 어휘 items are not won
/// by spelling — they are won by telling apart words that could all plausibly
/// fill the same slot (assert / allege / contend). So candidates are now scored
/// on several signals and spelling is only one of them.
///
/// The corpus has no part-of-speech, synonym or category columns (they are NULL
/// for every row), so nothing is invented: the signals are derived from data
/// that actually exists —
///
/// * **품사**: inferred from the shape of the Korean gloss (…하다 → 동사,
///   …한/…적인 → 형용사, …히/…게 → 부사, otherwise 명사).
/// * **의미 근접도**: character-bigram overlap between the Korean glosses, which
///   is what makes 저지하다 / 가로막다 compete.
/// * **같은 단원**: the corpus is stored in the order the chapters were added,
///   so neighbours in that order come from the same topical unit.
/// * **철자 유사도**: kept as a lower-weighted signal (the old behaviour).
final class DistractorService {

    static let shared = DistractorService()

    /// Coarse part of speech guessed from the Korean gloss.
    enum InferredPOS: String {
        case verb, adjective, adverb, noun
    }

    struct Candidate {
        let id: String
        let word: String
        let meaning: String
    }

    private struct IndexEntry {
        let id: String
        let word: String
        let lowercasedWord: String
        let meaning: String
        let posTags: Set<InferredPOS>
        let glossVariants: Set<String>
        let glossKeys: Set<String>
        let isPhrase: Bool
        let order: Int
    }

    /// Injected so the index can be built from a fixture in a test harness.
    var candidateProvider: () -> [Candidate] = { DatabaseManager.shared.fetchDistractorCandidates() }

    /// Immutable once built, so a question can score against a snapshot of it
    /// without holding the lock.
    private struct IndexSnapshot {
        let entries: [IndexEntry]
        let byPOS: [InferredPOS: [Int]]
        let byGlossKey: [String: [Int]]
        let byId: [String: Int]
    }

    private var snapshot: IndexSnapshot?
    private let lock = NSLock()

    private init() {}

    /// Drops the cached index; call after words are inserted or the bundled
    /// content is refreshed.
    func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        snapshot = nil
    }

    // MARK: - Public API

    /// Wrong *meanings* for an English → Korean question.
    func meaningDistractors(for word: Corpus, limit: Int) -> [Distractor] {
        distractors(for: word, sentence: nil, limit: limit, forContext: false)
    }

    /// Wrong *words* for a sentence-blank question. `sentence` is the blanked
    /// sentence, used to reject any candidate that already appears in it.
    func contextDistractors(for word: Corpus, sentence: String?, limit: Int) -> [Distractor] {
        distractors(for: word, sentence: sentence, limit: limit, forContext: true)
    }

    // MARK: - Selection

    private func distractors(for word: Corpus, sentence: String?, limit: Int, forContext: Bool) -> [Distractor] {
        guard limit > 0 else { return [] }
        let index = loadIndexIfNeeded()
        let entries = index.entries
        guard !entries.isEmpty else { return [] }

        let targetPOS = Self.inferPOS(fromMeaning: word.meaning)
        let targetGlossVariants = Self.glossVariants(word.meaning)
        let targetGlossKeys = Self.glossKeys(from: targetGlossVariants)
        let targetWord = word.word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let targetIsPhrase = targetWord.contains(" ")
        let targetOrder = index.byId[word.id].map { entries[$0].order } ?? -1

        var scored: [(score: Double, entry: IndexEntry)] = []
        scored.reserveCapacity(400)
        var seenWords = Set<String>([targetWord])

        for candidateIndex in candidateIndices(in: index, targetId: word.id, targetPOS: targetPOS, targetGlossKeys: targetGlossKeys) {
            let entry = entries[candidateIndex]
            if entry.id == word.id { continue }
            if seenWords.contains(entry.lowercasedWord) { continue }
            if entry.meaning.isEmpty || entry.word.isEmpty { continue }

            // A candidate that shares a whole gloss with the target is not a
            // wrong answer — it would be a second correct one.
            if !entry.glossVariants.isDisjoint(with: targetGlossVariants) { continue }

            if forContext {
                // Inflectional twins ("commute" / "commuter") could genuinely
                // fit the blank, so they are not offered as wrong answers.
                if Self.areInflectionalTwins(targetWord, entry.lowercasedWord) { continue }
            }

            seenWords.insert(entry.lowercasedWord)

            let posMatch = entry.posTags.isDisjoint(with: targetPOS) ? 0.0 : 1.0
            let gloss = Self.glossSimilarity(targetGlossKeys, entry.glossKeys)
            let spelling = Self.spellingSimilarity(targetWord, entry.lowercasedWord)
            let chapter = Self.chapterProximity(targetOrder, entry.order)
            let shape = (entry.isPhrase == targetIsPhrase) ? 1.0 : 0.0
            let jitter = Double.random(in: 0...0.35)

            let score: Double
            if forContext {
                score = 2.6 * posMatch
                    + 2.2 * gloss
                    + 1.0 * chapter
                    + 0.8 * shape
                    + 0.6 * spelling
                    + jitter
            } else {
                // Meaning questions keep spelling similarity as a strong signal
                // (that is the classic behaviour) but no longer rely on it alone.
                // Near-synonymous glosses are damped down instead of boosted:
                // an option that is almost a correct translation is unfair.
                let cappedGloss = gloss > 0.6 ? 0.0 : gloss
                score = 2.2 * posMatch
                    + 1.6 * spelling
                    + 1.2 * cappedGloss
                    + 0.5 * chapter
                    + jitter
            }
            scored.append((score, entry))
        }

        scored.sort { $0.score > $1.score }

        // The "does this option already appear in the sentence?" test is the
        // expensive one, so it runs on the ranked shortlist rather than on
        // every candidate: a word printed in the sentence would give the
        // answer away and must not be offered.
        var selected: [Distractor] = []
        for candidate in scored {
            if selected.count >= limit { break }
            if forContext, let sentence = sentence,
               ContextSentenceBuilder.sentenceContains(candidate.entry.word, sentence: sentence) {
                continue
            }
            selected.append(Distractor(id: candidate.entry.id, word: candidate.entry.word, meaning: candidate.entry.meaning))
        }
        return selected
    }

    /// Narrows the 2,600-word corpus down to a few hundred plausible candidates
    /// before scoring, so a question stays cheap to build.
    private func candidateIndices(in index: IndexSnapshot, targetId: String, targetPOS: Set<InferredPOS>, targetGlossKeys: Set<String>) -> [Int] {
        var picked = Set<Int>()
        let entryCount = index.entries.count

        // 1. Semantically overlapping words (shared Korean gloss fragments).
        for key in targetGlossKeys {
            guard let bucket = index.byGlossKey[key] else { continue }
            for entryIndex in bucket.prefix(40) {
                picked.insert(entryIndex)
            }
            if picked.count > 160 { break }
        }

        // 2. Same part of speech.
        for pos in targetPOS {
            guard let bucket = index.byPOS[pos], !bucket.isEmpty else { continue }
            let sampleSize = min(bucket.count, 200)
            for _ in 0..<sampleSize {
                picked.insert(bucket[Int.random(in: 0..<bucket.count)])
            }
        }

        // 3. A little noise from the whole corpus so options are not always
        //    drawn from the same neighbourhood.
        if entryCount > 0 {
            for _ in 0..<60 {
                picked.insert(Int.random(in: 0..<entryCount))
            }
        }

        if let selfIndex = index.byId[targetId] {
            picked.remove(selfIndex)
        }
        return Array(picked)
    }

    // MARK: - Index

    @discardableResult
    private func loadIndexIfNeeded() -> IndexSnapshot {
        lock.lock()
        let cached = snapshot
        lock.unlock()
        if let cached = cached { return cached }

        let candidates = candidateProvider()
        var built: [IndexEntry] = []
        built.reserveCapacity(candidates.count)
        var byPOS: [InferredPOS: [Int]] = [:]
        var byGloss: [String: [Int]] = [:]
        var byId: [String: Int] = [:]

        for (order, candidate) in candidates.enumerated() {
            let variants = Self.glossVariants(candidate.meaning)
            let keys = Self.glossKeys(from: variants)
            let pos = Self.inferPOS(fromMeaning: candidate.meaning)
            let trimmedWord = candidate.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = IndexEntry(
                id: candidate.id,
                word: trimmedWord,
                lowercasedWord: trimmedWord.lowercased(),
                meaning: candidate.meaning,
                posTags: pos,
                glossVariants: variants,
                glossKeys: keys,
                isPhrase: trimmedWord.contains(" "),
                order: order
            )
            let index = built.count
            built.append(entry)
            byId[entry.id] = index
            for tag in pos {
                byPOS[tag, default: []].append(index)
            }
            for key in keys {
                byGloss[key, default: []].append(index)
            }
        }

        let fresh = IndexSnapshot(entries: built, byPOS: byPOS, byGlossKey: byGloss, byId: byId)
        lock.lock()
        snapshot = fresh
        lock.unlock()
        return fresh
    }

    // MARK: - Korean gloss analysis

    /// Splits a stored meaning into its variants, ignoring the "﹒" separators
    /// that appear inside parentheses (they are word separators there).
    static func glossVariants(_ meaning: String) -> Set<String> {
        var variants: [String] = []
        var current = ""
        var depth = 0
        for character in meaning {
            if character == "(" || character == "（" {
                depth += 1
            } else if character == ")" || character == "）" {
                depth = max(0, depth - 1)
            }
            if character == "﹒" && depth == 0 {
                variants.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        variants.append(current)

        var result = Set<String>()
        for variant in variants {
            let normalized = normalizeGloss(variant)
            if !normalized.isEmpty {
                result.insert(normalized)
            }
        }
        return result
    }

    /// Strips parenthesised qualifiers, spacing and particles so that
    /// "(강하게) 주장하다" and "주장하다" compare equal.
    static func normalizeGloss(_ variant: String) -> String {
        var stripped = ""
        var depth = 0
        for character in variant {
            if character == "(" || character == "（" {
                depth += 1
                continue
            }
            if character == ")" || character == "）" {
                depth = max(0, depth - 1)
                continue
            }
            if depth == 0 {
                stripped.append(character)
            }
        }
        let removable = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "~-–—·,.;:'\"!?"))
        let filtered = String(String.UnicodeScalarView(stripped.unicodeScalars.filter { !removable.contains($0) }))
        return filtered
    }

    /// The stem of a gloss plus its character bigrams — the fragments that make
    /// two Korean definitions look alike.
    static func glossKeys(from variants: Set<String>) -> Set<String> {
        var keys = Set<String>()
        for variant in variants {
            let stem = stripGlossSuffix(variant)
            guard stem.count >= 2 else {
                if !stem.isEmpty { keys.insert(stem) }
                continue
            }
            keys.insert(stem)
            let characters = Array(stem)
            for index in 0..<(characters.count - 1) {
                keys.insert(String(characters[index...(index + 1)]))
            }
        }
        return keys
    }

    private static let glossSuffixes = ["시키다", "스러운", "로운", "하다", "되다", "적인", "하는", "되는", "이다", "한", "의", "적", "을", "를", "이", "가"]

    static func stripGlossSuffix(_ variant: String) -> String {
        var stem = variant
        for suffix in glossSuffixes where stem.hasSuffix(suffix) && stem.count > suffix.count + 1 {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        return stem
    }

    /// Part of speech guessed from the ending of each Korean gloss variant.
    static func inferPOS(fromMeaning meaning: String) -> Set<InferredPOS> {
        var tags = Set<InferredPOS>()
        for variant in glossVariants(meaning) {
            guard variant.count >= 2 else { continue }
            if variant.hasSuffix("하다") || variant.hasSuffix("되다") || variant.hasSuffix("시키다") || variant.hasSuffix("이다") || variant.hasSuffix("다") {
                tags.insert(.verb)
            } else if variant.hasSuffix("적인") || variant.hasSuffix("스러운") || variant.hasSuffix("로운") || variant.hasSuffix("운")
                        || variant.hasSuffix("한") || variant.hasSuffix("은") || variant.hasSuffix("는") || variant.hasSuffix("인") {
                tags.insert(.adjective)
            } else if variant.hasSuffix("히") || variant.hasSuffix("게") || variant.hasSuffix("으로") || variant.hasSuffix("로") {
                tags.insert(.adverb)
            } else {
                tags.insert(.noun)
            }
        }
        if tags.isEmpty { tags.insert(.noun) }
        return tags
    }

    // MARK: - Similarity signals

    static func glossSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let shared = lhs.intersection(rhs).count
        guard shared > 0 else { return 0 }
        return min(1.0, Double(shared) / Double(min(lhs.count, rhs.count)))
    }

    static func spellingSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let longest = max(lhs.count, rhs.count)
        guard longest > 0 else { return 0 }
        let distance = levenshteinDistance(lhs, rhs)
        return max(0.0, 1.0 - Double(distance) / Double(longest))
    }

    /// Words added close together belong to the same chapter of the word book,
    /// which is the closest thing this corpus has to a category.
    static func chapterProximity(_ lhs: Int, _ rhs: Int) -> Double {
        guard lhs >= 0, rhs >= 0 else { return 0 }
        let distance = abs(lhs - rhs)
        return 1.0 / (1.0 + Double(distance) / 25.0)
    }

    /// True for pairs like "commute"/"commuting" where one is (nearly) a
    /// prefix of the other — such an option may genuinely fit a blank.
    static func areInflectionalTwins(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        guard shorter.count >= 4 else { return levenshteinDistance(lhs, rhs) <= 1 }
        if longer.hasPrefix(shorter) && longer.count - shorter.count <= 3 { return true }
        return levenshteinDistance(lhs, rhs) <= 1
    }

    /// Minimum number of single-character edits between two strings.
    static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let source = Array(lhs)
        let target = Array(rhs)
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }

        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 0..<source.count {
            current[0] = i + 1
            for j in 0..<target.count {
                current[j + 1] = source[i] == target[j]
                    ? previous[j]
                    : min(previous[j], previous[j + 1], current[j]) + 1
            }
            previous = current
        }
        return previous[target.count]
    }
}
