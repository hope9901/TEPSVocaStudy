import Foundation

struct Corpus: Identifiable, Hashable, Codable {
    let id: String
    let vocabularyId: String
    let word: String
    let meaning: String
    let pos: String?
    let pronunciation: String?
    let desc: String?
    let synonym: String?
    let antonym: String?
    let image: String?
    var familiar: Int
    let isDeleted: Int
    let scheduledAt: String?
    let updatedAt: String
    let createdAt: String
    let exampleSentence: String?
    
    // Helper check to determine if this word is memorized
    var isMemorized: Bool {
        return familiar >= 3
    }
    
    // Check if the word is classified as "Hard Word" (Familiarity <= -3)
    var isHardWord: Bool {
        return familiar <= -3
    }
}

// Meanings imported from multiple sources are joined with "﹒" and frequently
// repeat the same translation (some run past 250 characters); keep only the
// first few unique variants when displaying them.
extension String {
    func condensedMeaning(maxVariants: Int = 2) -> String {
        // Split on "﹒" only outside parentheses — inside them it is a word
        // separator like "(문제﹒갈등을)", not a variant separator.
        var variants: [String] = []
        var current = ""
        var depth = 0
        for ch in self {
            if ch == "(" || ch == "（" {
                depth += 1
            } else if ch == ")" || ch == "）" {
                depth = max(0, depth - 1)
            }
            if ch == "﹒" && depth == 0 {
                variants.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        variants.append(current.trimmingCharacters(in: .whitespacesAndNewlines))

        var seen = Set<String>()
        let unique = variants.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return self }
        return unique.prefix(maxVariants).joined(separator: "﹒")
    }
}
