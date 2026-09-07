import Foundation
import SQLite3

// sqlite3_bind_text needs SQLITE_TRANSIENT so SQLite copies the string before
// Swift deallocates the temporary C string; passing nil (SQLITE_STATIC) is undefined behavior here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ScheduleDistribution {
    let todayOrOverdue: Int
    let within3Days: Int
    let within7Days: Int
    let within30Days: Int
    let over30Days: Int
}

class DatabaseManager {
    static let shared = DatabaseManager()
    // Internal (not private) so `DatabaseManager+Learning.swift` can reuse the
    // same connection and helpers instead of opening a second one.
    var db: OpaquePointer?
    
    // The unified vocabulary ID we migrated to
    let unifiedVocabId = "unified-teps-vocab-id"
    private let dbName = "v85_20260312T133124Z.db"

    // Bump this whenever the bundled DB's word content changes (typo fixes,
    // new words, …). Existing installs then sync the new content into their
    // Documents copy on next launch while keeping familiar/scheduledAt.
    private let bundledContentVersion = 3
    private let bundledContentVersionKey = "bundledContentVersion"
    
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
        var freshCopy = false
        if !fileManager.fileExists(atPath: dbURL.path) {
            if let bundleURL = Bundle.main.url(forResource: "v85_20260312T133124Z", withExtension: "db") {
                do {
                    try fileManager.copyItem(at: bundleURL, to: dbURL)
                    freshCopy = true
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
            // Additive schema for the SRS/statistics tables. Runs before the
            // content migration so both fresh and existing installs have them.
            ensureLearningSchema()
            migrateBundledContentIfNeeded(freshCopy: freshCopy)
        }
    }

    // MARK: - Bundled Content Migration

    /// Syncs word content (spelling, meanings, examples, deletions) from the
    /// bundled DB into the user's Documents copy without touching learning
    /// progress (familiar, scheduledAt). Runs once per bundledContentVersion bump.
    private func migrateBundledContentIfNeeded(freshCopy: Bool) {
        guard db != nil else { return }

        let defaults = UserDefaults.standard
        // A fresh copy already contains the latest content — just record the version.
        if freshCopy || defaults.integer(forKey: bundledContentVersionKey) >= bundledContentVersion {
            defaults.set(bundledContentVersion, forKey: bundledContentVersionKey)
            return
        }
        guard let bundleURL = Bundle.main.url(forResource: "v85_20260312T133124Z", withExtension: "db") else { return }

        // Attach the bundled DB read-only next to the Documents DB
        var attachStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS bundled;", -1, &attachStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(attachStmt, 1, bundleURL.path.cString(using: .utf8), -1, SQLITE_TRANSIENT)
        let attached = sqlite3_step(attachStmt) == SQLITE_DONE
        sqlite3_finalize(attachStmt)
        guard attached else {
            print("Migration: failed to attach bundled DB.")
            return
        }

        let migrationSQL = """
            BEGIN TRANSACTION;

            -- Refresh content of existing rows; familiar and scheduledAt stay untouched
            UPDATE Corpus SET
                word = b.word,
                meaning = b.meaning,
                pos = b.pos,
                pronunciation = b.pronunciation,
                "desc" = b."desc",
                synonym = b.synonym,
                antonym = b.antonym,
                image = b.image,
                exampleSentence = b.exampleSentence,
                isDeleted = b.isDeleted,
                updatedAt = b.updatedAt
            FROM bundled.Corpus AS b
            WHERE Corpus.id = b.id;

            -- Add words that are new in the bundle (user-added words are untouched)
            INSERT INTO Corpus (id, vocabularyId, word, meaning, pos, pronunciation, "desc",
                                synonym, antonym, image, familiar, isDeleted, scheduledAt,
                                updatedAt, createdAt, exampleSentence)
            SELECT b.id, b.vocabularyId, b.word, b.meaning, b.pos, b.pronunciation, b."desc",
                   b.synonym, b.antonym, b.image, b.familiar, b.isDeleted, b.scheduledAt,
                   b.updatedAt, b.createdAt, b.exampleSentence
            FROM bundled.Corpus AS b
            WHERE b.id NOT IN (SELECT id FROM Corpus);

            COMMIT;
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, migrationSQL, nil, nil, &errMsg) == SQLITE_OK {
            defaults.set(bundledContentVersion, forKey: bundledContentVersionKey)
            print("Migration: bundled content v\(bundledContentVersion) synced (progress preserved).")
        } else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            print("Migration failed: \(message)")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
        sqlite3_free(errMsg)
        sqlite3_exec(db, "DETACH DATABASE bundled;", nil, nil, nil)

        // Refresh cached vocabulary statistics after content changes
        updateVocabularyStatistics()
        // Meanings/examples may have changed — drop the cached distractor index.
        DistractorService.shared.invalidateCache()
    }
    
    // MARK: - Core Query Operations
    
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
    
    /// Candidate rows for the distractor index, in the order the corpus was
    /// built up (that order is the closest thing this data has to a chapter).
    func fetchDistractorCandidates() -> [DistractorService.Candidate] {
        guard let db = db else { return [] }
        var candidates: [DistractorService.Candidate] = []

        let query = """
            SELECT id, word, meaning
            FROM Corpus
            WHERE vocabularyId = ? AND isDeleted = 0 AND word <> '' AND meaning <> ''
            ORDER BY datetime(createdAt) ASC, id ASC;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, unifiedVocabId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let wordText = sqlite3_column_text(statement, 1),
                      let meaningText = sqlite3_column_text(statement, 2) else { continue }
                candidates.append(
                    DistractorService.Candidate(
                        id: String(cString: idText),
                        word: String(cString: wordText),
                        meaning: String(cString: meaningText)
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return candidates
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
            DistractorService.shared.invalidateCache()
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
    
    enum SQLParam {
        case text(String)
        case integer(Int)
        case null
    }
    
    func executeQuery(query: String, params: [SQLParam] = []) -> [Corpus] {
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
                case .null:
                    sqlite3_bind_null(statement, bindIndex)
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
    
    func updateVocabularyStatistics() {
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
