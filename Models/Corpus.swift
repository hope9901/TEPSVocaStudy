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
