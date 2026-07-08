import Foundation
import SQLite3

// sqlite3_bind_text needs SQLITE_TRANSIENT so SQLite copies the string before
// Swift deallocates the temporary C string; passing nil (SQLITE_STATIC) is undefined behavior here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Distractor: Hashable {
    let word: String
    let meaning: String
}

struct ScheduleDistribution {
    let todayOrOverdue: Int
    let within3Days: Int
    let within7Days: Int
    let within30Days: Int
    let over30Days: Int
}

class DatabaseManager {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    
    // The unified vocabulary ID we migrated to
    private let unifiedVocabId = "unified-teps-vocab-id"
    private let dbName = "v85_20260312T133124Z.db"
    
    private init() {
        openDatabase()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    private func openDatabase() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("Failed to get documents directory URL.")
            return
        }
        
        let dbURL = documentsURL.appendingPathComponent(dbName)
        print("Database path: \(dbURL.path)")
        
        // Copy DB from bundle if not present in Documents
        if !fileManager.fileExists(atPath: dbURL.path) {
            if let bundleURL = Bundle.main.url(forResource: "v85_20260312T133124Z", withExtension: "db") {
                do {
                    try fileManager.copyItem(at: bundleURL, to: dbURL)
                    print("Successfully copied database from Bundle to Documents.")
                } catch {
                    print("Error copying database: \(error.localizedDescription)")
                }
            } else {
                // If it is not in bundle, create empty database
                print("Database not found in Bundle, creating empty database in Documents.")
            }
        }
        
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("Failed to open database.")
            db = nil
        } else {
            print("Successfully opened database.")
            // Enable Foreign keys
            sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        }
    }
    
    // MARK: - Core Query Operations
    
    /// Fetches up to `limit` words for studying. 
    /// Prioritizes scheduled review words (scheduledAt <= now). 
    /// Falls back to unmemorized words (familiar < 3) to fill the quota.
    func fetchStudyWords(limit: Int) -> [Corpus] {
        var words: [Corpus] = []
        guard db != nil else { return words }
        
        // 1. Fetch scheduled review words
        let scheduledQuery = """
            SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence 
            FROM Corpus 
            WHERE vocabularyId = ? AND isDeleted = 0 AND datetime(scheduledAt) <= datetime('now')
            ORDER BY RANDOM() 
            LIMIT ?;
        """
        words = executeQuery(query: scheduledQuery, params: [.text(unifiedVocabId), .integer(limit)])
        
        // 2. Fallback: if not enough scheduled words, fetch unmemorized words (familiar < 3)
        if words.count < limit {
            let needed = limit - words.count
            let fallbackQuery = """
                SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence 
                FROM Corpus 
                WHERE vocabularyId = ? AND isDeleted = 0 AND familiar < 3 AND id NOT IN (
                    SELECT id FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND datetime(scheduledAt) <= datetime('now')
                )
                ORDER BY RANDOM() 
                LIMIT ?;
            """
            let fallbackWords = executeQuery(query: fallbackQuery, params: [.text(unifiedVocabId), .text(unifiedVocabId), .integer(needed)])
            words.append(contentsOf: fallbackWords)
        }
        
        // 3. Final Fallback: if still not enough, fetch any active words
        if words.count < limit {
            let needed = limit - words.count
            let existingIds = Set(words.map { $0.id })
            
            let finalQuery = """
                SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence 
                FROM Corpus 
                WHERE vocabularyId = ? AND isDeleted = 0
                ORDER BY RANDOM() 
                LIMIT ?;
            """
            let finalWords = executeQuery(query: finalQuery, params: [.text(unifiedVocabId), .integer(needed * 2)]) // Fetch a bit extra
            
            for word in finalWords {
                if !existingIds.contains(word.id) && words.count < limit {
                    words.append(word)
                }
            }
        }
        
        return words
    }
    
    /// Fetches all "Hard Words" (familiar <= -3)
    func fetchHardWords() -> [Corpus] {
        let query = """
            SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence 
            FROM Corpus 
            WHERE vocabularyId = ? AND isDeleted = 0 AND familiar <= -3
            ORDER BY familiar ASC, word ASC;
        """
        return executeQuery(query: query, params: [.text(unifiedVocabId)])
    }
    
    /// Fetches words that are spelling-wise similar to the correct word to make distractors highly plausible.
    func fetchDistractorMeanings(correctWord: String, correctId: String, limit: Int) -> [Distractor] {
        var distractors: [Distractor] = []
        guard let db = db else { return distractors }
        
        // Fetch 60 random active words (excluding correct word) from the database to screen spelling similarities
        let query = """
            SELECT id, word, meaning 
            FROM Corpus 
            WHERE id != ? AND vocabularyId = ? AND isDeleted = 0 AND meaning != ''
            ORDER BY RANDOM() 
            LIMIT 60;
        """
        
        struct Candidate {
            let word: String
            let meaning: String
            let distance: Int
        }
        
        var candidates: [Candidate] = []
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, correctId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let word = String(cString: sqlite3_column_text(statement, 1))
                let meaning = String(cString: sqlite3_column_text(statement, 2))
                
                // Calculate distance between lowercase versions
                let distance = levenshteinDistance(
                    s1: correctWord.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                    s2: word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                )
                
                candidates.append(Candidate(word: word, meaning: meaning, distance: distance))
            }
        }
        sqlite3_finalize(statement)
        
        // Sort by distance ascending (closest spelling matches first)
        candidates.sort(by: { $0.distance < $1.distance })
        
        // Take the top 'limit' candidates' meanings
        for candidate in candidates.prefix(limit) {
            distractors.append(Distractor(word: candidate.word, meaning: candidate.meaning))
        }
        
        // Fallback in case we got fewer than limit
        while distractors.count < limit {
            distractors.append(Distractor(word: "distractor\(distractors.count + 1)", meaning: "임시 오답 \(distractors.count + 1)"))
        }
        
        return distractors
    }
    
    // Levenshtein Distance Algorithm (determines minimum edits to transform s1 to s2)
    private func levenshteinDistance(s1: String, s2: String) -> Int {
        let empty = [Int](repeating: 0, count: s2.count + 1)
        var last = [Int](repeating: 0, count: s2.count + 1)
        for i in 0...s2.count { last[i] = i }
        
        for (i, char1) in s1.enumerated() {
            var current = empty
            current[0] = i + 1
            for (j, char2) in s2.enumerated() {
                current[j + 1] = char1 == char2 ? last[j] : min(last[j], last[j + 1], current[j]) + 1
            }
            last = current
        }
        return last[s2.count]
    }
    
    /// Updates word familiarity score (+1 for correct, -1 for incorrect, bounds it between -5 and 5).
    /// Calculates the next review date (scheduledAt) based on Ebbinghaus Spaced Repetition.
    /// Also updates the Vocabulary counts.
    func updateFamiliarity(id: String, increment: Int) {
        guard let db = db else { return }
        
        // 1. Fetch current familiarity
        var currentFamiliarity = 0
        let fetchQuery = "SELECT familiar FROM Corpus WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, fetchQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentFamiliarity = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        // Apply increment and clamp between -5 and 5
        let newFamiliarity = max(-5, min(5, currentFamiliarity + increment))
        
        // 2. Calculate Ebbinghaus scheduledAt date
        let now = Date()
        let calendar = Calendar.current
        var daysToAdd = 0
        
        if increment > 0 {
            // Correct answer: schedule into the future based on how well it is known
            switch newFamiliarity {
            case ...1:
                daysToAdd = 1   // Review in 1 day
            case 2:
                daysToAdd = 3   // Review in 3 days
            case 3:
                daysToAdd = 7   // Review in 7 days
            case 4:
                daysToAdd = 14  // Review in 14 days
            default:
                daysToAdd = 30  // Review in 30 days
            }
        } else {
            // Incorrect answer: review today/now (daysToAdd = 0)
            daysToAdd = 0
        }
        
        let scheduledDate = calendar.date(byAdding: .day, value: daysToAdd, to: now) ?? now
        
        // Format ISO8601 string for SQLite (YYYY-MM-DD HH:MM:SS.SSSZ format or ISO8601)
        let formatter = ISO8601DateFormatter()
        let scheduledStr = formatter.string(from: scheduledDate)
        let nowStr = formatter.string(from: now)
        
        // 3. Update familiarity and scheduledAt in Corpus
        let updateQuery = "UPDATE Corpus SET familiar = ?, scheduledAt = ?, updatedAt = ? WHERE id = ?;"
        if sqlite3_prepare_v2(db, updateQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(newFamiliarity))
            sqlite3_bind_text(stmt, 2, scheduledStr.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, nowStr.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, id.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("Failed to update familiarity for \(id).")
            }
        }
        sqlite3_finalize(stmt)
        
        // 4. Recalculate Vocabulary stats and update them
        updateVocabularyStatistics()
    }
    
    /// Inserts a new word into the DB
    func insertWord(word: String, meaning: String, example: String) -> Bool {
        guard let db = db else { return false }
        
        let newId = UUID().uuidString.lowercased()
        let nowStr = ISO8601DateFormatter().string(from: Date())
        
        let query = """
            INSERT INTO Corpus (id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence)
            VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, 0, 0, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        var success = false
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, newId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, word.trimmingCharacters(in: .whitespacesAndNewlines).cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, meaning.trimmingCharacters(in: .whitespacesAndNewlines).cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, nowStr.cString(using: .utf8), -1, SQLITE_TRANSIENT) // scheduledAt gets created time (today)
            sqlite3_bind_text(stmt, 6, nowStr.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, nowStr.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, example.trimmingCharacters(in: .whitespacesAndNewlines).cString(using: .utf8), -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
            } else {
                print("SQLite insert error: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)
        
        if success {
            updateVocabularyStatistics()
        }
        
        return success
    }
    
    /// Real-time search of words starting with prefix (autocomplete)
    func searchWords(prefix: String) -> [Corpus] {
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "%"
        
        let query = """
            SELECT id, vocabularyId, word, meaning, pos, pronunciation, desc, synonym, antonym, image, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence 
            FROM Corpus 
            WHERE vocabularyId = ? AND isDeleted = 0 AND word LIKE ?
            ORDER BY word ASC
            LIMIT 15;
        """
        
        return executeQuery(query: query, params: [.text(unifiedVocabId), .text(cleanPrefix)])
    }
    
    /// Exact match check if word already exists in the database
    func checkWordExists(word: String) -> Bool {
        guard let db = db else { return false }
        let cleanWord = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let query = "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND LOWER(word) = ?;"
        var stmt: OpaquePointer?
        var exists = false
        
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, cleanWord.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                let count = sqlite3_column_int(stmt, 0)
                exists = count > 0
            }
        }
        sqlite3_finalize(stmt)
        return exists
    }
    
    /// Fetches vocabulary summary statistics (total words, familiar, unfamiliar, hard words count)
    func fetchStatistics() -> (total: Int, familiar: Int, unfamiliar: Int, hard: Int) {
        var total = 0
        var familiar = 0
        var unfamiliar = 0
        var hard = 0
        
        guard let db = db else { return (0, 0, 0, 0) }
        
        // Total
        let totalQuery = "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, totalQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        // Familiar (familiar >= 3)
        let familiarQuery = "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND familiar >= 3;"
        if sqlite3_prepare_v2(db, familiarQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                familiar = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        // Hard words (familiar <= -3)
        let hardQuery = "SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0 AND familiar <= -3;"
        if sqlite3_prepare_v2(db, hardQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                hard = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        
        unfamiliar = total - familiar
        return (total, familiar, unfamiliar, hard)
    }
    
    // MARK: - Private Helpers
    
    private enum SQLParam {
        case text(String)
        case integer(Int)
    }
    
    private func executeQuery(query: String, params: [SQLParam] = []) -> [Corpus] {
        var list: [Corpus] = []
        guard let db = db else { return list }
        
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            // Bind arguments dynamically
            for (index, param) in params.enumerated() {
                let bindIndex = Int32(index + 1)
                switch param {
                case .text(let value):
                    sqlite3_bind_text(statement, bindIndex, value.cString(using: .utf8), -1, SQLITE_TRANSIENT)
                case .integer(let value):
                    sqlite3_bind_int(statement, bindIndex, Int32(value))
                }
            }
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let vocabId = String(cString: sqlite3_column_text(statement, 1))
                let word = String(cString: sqlite3_column_text(statement, 2))
                let meaning = String(cString: sqlite3_column_text(statement, 3))
                
                let pos = sqlite3_column_text(statement, 4).map { String(cString: $0) }
                let pronunciation = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                let desc = sqlite3_column_text(statement, 6).map { String(cString: $0) }
                let synonym = sqlite3_column_text(statement, 7).map { String(cString: $0) }
                let antonym = sqlite3_column_text(statement, 8).map { String(cString: $0) }
                let image = sqlite3_column_text(statement, 9).map { String(cString: $0) }
                
                let familiar = Int(sqlite3_column_int(statement, 10))
                let isDeleted = Int(sqlite3_column_int(statement, 11))
                
                let scheduledAt = sqlite3_column_text(statement, 12).map { String(cString: $0) }
                let updatedAt = String(cString: sqlite3_column_text(statement, 13))
                let createdAt = String(cString: sqlite3_column_text(statement, 14))
                
                let exampleSentence = sqlite3_column_text(statement, 15).map { String(cString: $0) }
                
                let item = Corpus(
                    id: id,
                    vocabularyId: vocabId,
                    word: word,
                    meaning: meaning,
                    pos: pos,
                    pronunciation: pronunciation,
                    desc: desc,
                    synonym: synonym,
                    antonym: antonym,
                    image: image,
                    familiar: familiar,
                    isDeleted: isDeleted,
                    scheduledAt: scheduledAt,
                    updatedAt: updatedAt,
                    createdAt: createdAt,
                    exampleSentence: exampleSentence
                )
                list.append(item)
            }
        } else {
            if let db = self.db {
                print("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(statement)
        return list
    }
    
    private func updateVocabularyStatistics() {
        guard let db = db else { return }
        
        let stats = fetchStatistics()
        
        let updateVocabQuery = """
            UPDATE Vocabulary 
            SET total = ?, nFamiliar = ?, nUnfamiliar = ?, updatedAt = datetime('now') 
            WHERE id = ?;
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateVocabQuery, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(stats.total))
            sqlite3_bind_int(stmt, 2, Int32(stats.familiar))
            sqlite3_bind_int(stmt, 3, Int32(stats.unfamiliar))
            sqlite3_bind_text(stmt, 4, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("Failed to update Vocabulary statistics.")
            }
        }
        sqlite3_finalize(stmt)
    }
    
    /// Fetches the spaced repetition review schedule distribution count for the dashboard visualization.
    func fetchScheduleDistribution() -> ScheduleDistribution {
        var todayOrOverdue = 0
        var within3Days = 0
        var within7Days = 0
        var within30Days = 0
        var over30Days = 0
        
        guard let db = db else {
            return ScheduleDistribution(todayOrOverdue: 0, within3Days: 0, within7Days: 0, within30Days: 0, over30Days: 0)
        }
        
        let query = """
            SELECT 
                SUM(CASE WHEN datetime(scheduledAt) <= datetime('now') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(scheduledAt) > datetime('now') AND datetime(scheduledAt) <= datetime('now', '+3 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(scheduledAt) > datetime('now', '+3 days') AND datetime(scheduledAt) <= datetime('now', '+7 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(scheduledAt) > datetime('now', '+7 days') AND datetime(scheduledAt) <= datetime('now', '+30 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(scheduledAt) > datetime('now', '+30 days') THEN 1 ELSE 0 END)
            FROM Corpus 
            WHERE vocabularyId = ? AND isDeleted = 0;
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                todayOrOverdue = Int(sqlite3_column_int(stmt, 0))
                within3Days = Int(sqlite3_column_int(stmt, 1))
                within7Days = Int(sqlite3_column_int(stmt, 2))
                within30Days = Int(sqlite3_column_int(stmt, 3))
                over30Days = Int(sqlite3_column_int(stmt, 4))
            }
        }
        sqlite3_finalize(stmt)
        
        return ScheduleDistribution(
            todayOrOverdue: todayOrOverdue,
            within3Days: within3Days,
            within7Days: within7Days,
            within30Days: within30Days,
            over30Days: over30Days
        )
    }
}
