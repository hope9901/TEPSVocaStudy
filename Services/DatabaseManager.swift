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
    private var db: OpaquePointer?

    // The unified vocabulary ID we migrated to
    private let unifiedVocabId = "unified-teps-vocab-id"
    private static let dbName = "v85_20260312T133124Z.db"

    // Bump this whenever the bundled DB's word content changes (typo fixes,
    // new words, …). Existing installs then sync the new content into their
    // Documents copy on next launch while keeping familiar/scheduledAt.
    private let bundledContentVersion = 3
    private let bundledContentVersionKey = "bundledContentVersion"

    // Learning-schema version, stored inside the DB (StudyMeta table) so a DB file
    // copied between installs via the Files app carries its own state.
    // PRAGMA user_version is not usable: the bundled DB already uses it (= 85).
    private let learningSchemaVersion = 1

    private let bundledURL: URL?
    private let defaults: UserDefaults

    private convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.init(
            databaseURL: documents.appendingPathComponent(DatabaseManager.dbName),
            bundledURL: Bundle.main.url(forResource: "v85_20260312T133124Z", withExtension: "db"),
            defaults: .standard
        )
    }

    /// Opens (copying from `bundledURL` on first use) the DB at `databaseURL`.
    /// Tests pass a temporary path and their own defaults suite.
    init(databaseURL: URL, bundledURL: URL?, defaults: UserDefaults) {
        self.bundledURL = bundledURL
        self.defaults = defaults
        openDatabase(at: databaseURL)
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func openDatabase(at dbURL: URL) {
        let fileManager = FileManager.default
        print("Database path: \(dbURL.path)")

        // Copy DB from bundle if not present in Documents
        var freshCopy = false
        if !fileManager.fileExists(atPath: dbURL.path) {
            if let bundleURL = bundledURL {
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
            migrateBundledContentIfNeeded(freshCopy: freshCopy)
            migrateLearningSchemaIfNeeded()
        }
    }

    // MARK: - Bundled Content Migration

    /// Syncs word content (spelling, meanings, examples, deletions) from the
    /// bundled DB into the user's Documents copy without touching learning
    /// progress (familiar, scheduledAt). Runs once per bundledContentVersion bump.
    private func migrateBundledContentIfNeeded(freshCopy: Bool) {
        guard db != nil else { return }

        // A fresh copy already contains the latest content — just record the version.
        if freshCopy || defaults.integer(forKey: bundledContentVersionKey) >= bundledContentVersion {
            defaults.set(bundledContentVersion, forKey: bundledContentVersionKey)
            return
        }
        guard let bundleURL = bundledURL else { return }

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
    }

    // MARK: - Learning Schema Migration

    /// Adds the SRS tables next to Corpus (Corpus itself is untouched, so the
    /// bundled-content sync and older app versions keep working) and imports the
    /// progress of words already studied in this app.
    private func migrateLearningSchemaIfNeeded() {
        guard db != nil else { return }
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS StudyMeta (key TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL);", nil, nil, nil)
        guard storedSchemaVersion() < learningSchemaVersion else { return }

        // Words studied in this app have scheduledAt written by ISO8601DateFormatter
        // ("2026-08-06T10:31:44Z"); bundled/legacy rows use "2025-11-17 14:59:08.65Z".
        // A user-added word that was never answered still has scheduledAt == createdAt.
        // The old ladder (familiar ≤1→1d, 2→3d, 3→7d, 4→14d, 5→30d) maps onto the new
        // ladder index, so the next correct answer continues the same progression.
        let sql = """
            BEGIN TRANSACTION;

            CREATE TABLE IF NOT EXISTS WordProgress (
                corpusId TEXT NOT NULL PRIMARY KEY,
                srsState INTEGER NOT NULL DEFAULT 1,
                intervalDays INTEGER NOT NULL DEFAULT 0,
                reviewStreak INTEGER NOT NULL DEFAULT 0,
                lapses INTEGER NOT NULL DEFAULT 0,
                firstStudiedAt TEXT,
                lastReviewedAt TEXT,
                nextReviewAt TEXT NOT NULL,
                meaningCorrect INTEGER NOT NULL DEFAULT 0,
                meaningWrong INTEGER NOT NULL DEFAULT 0,
                contextCorrect INTEGER NOT NULL DEFAULT 0,
                contextWrong INTEGER NOT NULL DEFAULT 0,
                recallCorrect INTEGER NOT NULL DEFAULT 0,
                recallWrong INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_wordprogress_next ON WordProgress(nextReviewAt);

            CREATE TABLE IF NOT EXISTS ReviewLog (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                corpusId TEXT NOT NULL,
                reviewedAt TEXT NOT NULL,
                quizType INTEGER NOT NULL,
                context INTEGER NOT NULL,
                correct INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_reviewlog_time ON ReviewLog(reviewedAt);

            INSERT OR IGNORE INTO WordProgress
                (corpusId, srsState, intervalDays, reviewStreak, lapses, firstStudiedAt, lastReviewedAt, nextReviewAt)
            SELECT id,
                   CASE WHEN familiar >= 2 THEN 2 ELSE 1 END,
                   CASE WHEN familiar <= 1 THEN 1 WHEN familiar = 2 THEN 3 WHEN familiar = 3 THEN 7
                        WHEN familiar = 4 THEN 14 ELSE 30 END,
                   CASE WHEN familiar <= 1 THEN 0 WHEN familiar >= 5 THEN 4 ELSE familiar - 1 END,
                   0, NULL, NULL, scheduledAt
            FROM Corpus
            WHERE vocabularyId = '\(unifiedVocabId)'
              AND instr(scheduledAt, 'T') > 0
              AND scheduledAt != createdAt;

            INSERT OR REPLACE INTO StudyMeta (key, value) VALUES ('learningSchemaVersion', \(learningSchemaVersion));
            COMMIT;
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK {
            print("Learning schema v\(learningSchemaVersion) ready (existing progress imported).")
        } else {
            print("Learning schema migration failed: \(errMsg.map { String(cString: $0) } ?? "unknown")")
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        }
        sqlite3_free(errMsg)
    }

    private func storedSchemaVersion() -> Int {
        countQuery("SELECT value FROM StudyMeta WHERE key = 'learningSchemaVersion';", params: [])
    }

    // MARK: - Core Query Operations

    private let corpusColumns = "c.id, c.vocabularyId, c.word, c.meaning, c.pos, c.pronunciation, c.desc, c.synonym, c.antonym, c.image, c.familiar, c.isDeleted, c.scheduledAt, c.updatedAt, c.createdAt, c.exampleSentence"

    /// Words whose review date has arrived, most overdue first.
    /// Only words that have SRS progress can be due — a NEW word is never "due",
    /// and a word scheduled for the future is never returned.
    func fetchDueWords(now: Date = Date(), limit: Int) -> [Corpus] {
        let query = """
            SELECT \(corpusColumns)
            FROM Corpus c JOIN WordProgress p ON p.corpusId = c.id
            WHERE c.vocabularyId = ? AND c.isDeleted = 0 AND p.nextReviewAt <= ?
            ORDER BY p.nextReviewAt ASC
            LIMIT ?;
        """
        return executeQuery(query: query, params: [.text(unifiedVocabId), .text(StudyClock.iso(now)), .integer(limit)])
    }

    /// Words never studied in this app (no SRS progress yet).
    func fetchNewWords(limit: Int) -> [Corpus] {
        guard limit > 0 else { return [] }
        let query = """
            SELECT \(corpusColumns)
            FROM Corpus c LEFT JOIN WordProgress p ON p.corpusId = c.id
            WHERE c.vocabularyId = ? AND c.isDeleted = 0 AND p.corpusId IS NULL
            ORDER BY RANDOM()
            LIMIT ?;
        """
        return executeQuery(query: query, params: [.text(unifiedVocabId), .integer(limit)])
    }

    /// Every active word — the candidate pool for distractors.
    func fetchAllActiveWords() -> [Corpus] {
        let query = "SELECT \(corpusColumns) FROM Corpus c WHERE c.vocabularyId = ? AND c.isDeleted = 0;"
        return executeQuery(query: query, params: [.text(unifiedVocabId)])
    }

    /// Number of words introduced (first answered) since `start`.
    func countNewWordsStudied(since start: Date) -> Int {
        countQuery(
            "SELECT COUNT(*) FROM ReviewLog WHERE context = \(ReviewContext.newWord.rawValue) AND reviewedAt >= ?;",
            params: [.text(StudyClock.iso(start))]
        )
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

    // MARK: - Recording Answers

    func fetchProgress(corpusId: String) -> WordProgress? {
        guard let db = db else { return nil }
        let query = """
            SELECT srsState, intervalDays, reviewStreak, lapses, firstStudiedAt, lastReviewedAt, nextReviewAt,
                   meaningCorrect, meaningWrong, contextCorrect, contextWrong, recallCorrect, recallWrong
            FROM WordProgress WHERE corpusId = ?;
        """
        var stmt: OpaquePointer?
        var result: WordProgress?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, corpusId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = WordProgress(
                    corpusId: corpusId,
                    state: SRSState(rawValue: Int(sqlite3_column_int(stmt, 0))) ?? .learning,
                    intervalDays: Int(sqlite3_column_int(stmt, 1)),
                    reviewStreak: Int(sqlite3_column_int(stmt, 2)),
                    lapses: Int(sqlite3_column_int(stmt, 3)),
                    firstStudiedAt: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    lastReviewedAt: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    nextReviewAt: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
                    meaningCorrect: Int(sqlite3_column_int(stmt, 7)),
                    meaningWrong: Int(sqlite3_column_int(stmt, 8)),
                    contextCorrect: Int(sqlite3_column_int(stmt, 9)),
                    contextWrong: Int(sqlite3_column_int(stmt, 10)),
                    recallCorrect: Int(sqlite3_column_int(stmt, 11)),
                    recallWrong: Int(sqlite3_column_int(stmt, 12))
                )
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// The scoring context of a first answer: NEW, due REVIEW, or an off-schedule DRILL.
    func reviewContext(forCorpusId corpusId: String, now: Date = Date()) -> ReviewContext {
        guard let progress = fetchProgress(corpusId: corpusId) else { return .newWord }
        return progress.nextReviewAt <= StudyClock.iso(now) ? .review : .drill
    }

    /// Records the first answer to a word in a session.
    /// NEW and due words update the SRS schedule; a drill on a not-yet-due word
    /// only moves `familiar` (so hard words can still graduate) and never
    /// pulls its review date forward or pushes it back.
    @discardableResult
    func recordFirstAnswer(corpusId: String, quizType: QuizType, correct: Bool, now: Date = Date()) -> ReviewContext {
        let context = reviewContext(forCorpusId: corpusId, now: now)
        let familiar = fetchFamiliar(corpusId: corpusId)
        let nowISO = StudyClock.iso(now)

        if context == .drill {
            let newFamiliar = max(-5, min(5, familiar + (correct ? 1 : -1)))
            execute("UPDATE Corpus SET familiar = ?, updatedAt = ? WHERE id = ?;",
                    params: [.integer(newFamiliar), .text(nowISO), .text(corpusId)])
        } else {
            let outcome = SRSScheduler.apply(
                existing: fetchProgress(corpusId: corpusId),
                corpusId: corpusId,
                familiar: familiar,
                quizType: quizType,
                correct: correct,
                now: now
            )
            saveProgress(outcome.progress)
            // Mirror into Corpus so older builds and the hard-word feature stay consistent.
            execute("UPDATE Corpus SET familiar = ?, scheduledAt = ?, updatedAt = ? WHERE id = ?;",
                    params: [.integer(outcome.familiar), .text(outcome.progress.nextReviewAt), .text(nowISO), .text(corpusId)])
        }

        logReview(corpusId: corpusId, quizType: quizType, context: context, correct: correct, now: now)
        updateVocabularyStatistics()
        return context
    }

    /// Same-session correction (typing review, re-quiz). Logged for statistics only:
    /// it must not touch familiar, the schedule, or mastery counters.
    func recordCorrection(corpusId: String, quizType: QuizType, correct: Bool, now: Date = Date()) {
        logReview(corpusId: corpusId, quizType: quizType, context: .correction, correct: correct, now: now)
    }

    private func saveProgress(_ p: WordProgress) {
        execute("""
            INSERT OR REPLACE INTO WordProgress
                (corpusId, srsState, intervalDays, reviewStreak, lapses, firstStudiedAt, lastReviewedAt, nextReviewAt,
                 meaningCorrect, meaningWrong, contextCorrect, contextWrong, recallCorrect, recallWrong)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, params: [
                .text(p.corpusId), .integer(p.state.rawValue), .integer(p.intervalDays), .integer(p.reviewStreak),
                .integer(p.lapses), p.firstStudiedAt.map(SQLParam.text) ?? .null, p.lastReviewedAt.map(SQLParam.text) ?? .null,
                .text(p.nextReviewAt), .integer(p.meaningCorrect), .integer(p.meaningWrong), .integer(p.contextCorrect),
                .integer(p.contextWrong), .integer(p.recallCorrect), .integer(p.recallWrong)
            ])
    }

    private func logReview(corpusId: String, quizType: QuizType, context: ReviewContext, correct: Bool, now: Date) {
        execute("INSERT INTO ReviewLog (corpusId, reviewedAt, quizType, context, correct) VALUES (?, ?, ?, ?, ?);",
                params: [.text(corpusId), .text(StudyClock.iso(now)), .integer(quizType.rawValue),
                         .integer(context.rawValue), .integer(correct ? 1 : 0)])
    }

    private func fetchFamiliar(corpusId: String) -> Int {
        countQuery("SELECT familiar FROM Corpus WHERE id = ?;", params: [.text(corpusId)])
    }

    // MARK: - Learning Statistics

    func fetchStateCounts(now: Date = Date()) -> StateCounts {
        let nowISO = StudyClock.iso(now)
        let total = countQuery("SELECT COUNT(*) FROM Corpus WHERE vocabularyId = ? AND isDeleted = 0;",
                               params: [.text(unifiedVocabId)])
        let joined = "FROM WordProgress p JOIN Corpus c ON c.id = p.corpusId WHERE c.vocabularyId = ? AND c.isDeleted = 0"
        let studied = countQuery("SELECT COUNT(*) \(joined);", params: [.text(unifiedVocabId)])
        let due = countQuery("SELECT COUNT(*) \(joined) AND p.nextReviewAt <= ?;", params: [.text(unifiedVocabId), .text(nowISO)])
        let mastered = countQuery("SELECT COUNT(*) \(joined) AND p.nextReviewAt > ? AND p.srsState = \(SRSState.mastered.rawValue);",
                                  params: [.text(unifiedVocabId), .text(nowISO)])
        return StateCounts(new: total - studied, learning: studied - due - mastered, due: due, mastered: mastered)
    }

    func fetchTodayStats(now: Date = Date(), dailyNewLimit: Int) -> TodayStats {
        let startISO = StudyClock.iso(StudyClock.startOfDay(now))
        let states = fetchStateCounts(now: now)
        let newStudied = countQuery("SELECT COUNT(*) FROM ReviewLog WHERE context = 0 AND reviewedAt >= ?;", params: [.text(startISO)])
        let reviewCorrect = countQuery("SELECT COUNT(*) FROM ReviewLog WHERE context = 1 AND correct = 1 AND reviewedAt >= ?;", params: [.text(startISO)])
        let reviewWrong = countQuery("SELECT COUNT(*) FROM ReviewLog WHERE context = 1 AND correct = 0 AND reviewedAt >= ?;", params: [.text(startISO)])
        return TodayStats(
            newStudied: newStudied,
            reviewCorrect: reviewCorrect,
            reviewWrong: reviewWrong,
            dueRemaining: states.due,
            newRemaining: min(states.new, max(0, dailyNewLimit - newStudied))
        )
    }

    /// Last-7-day accuracy, keeping long-term SRS evidence and same-session retests apart.
    func fetchAccuracyReport(now: Date = Date()) -> AccuracyReport {
        let sinceISO = StudyClock.iso(now.addingTimeInterval(-7 * 86_400))
        func accuracy(_ condition: String) -> Accuracy {
            let base = "FROM ReviewLog WHERE reviewedAt >= ? AND \(condition)"
            return Accuracy(
                correct: countQuery("SELECT COUNT(*) \(base) AND correct = 1;", params: [.text(sinceISO)]),
                total: countQuery("SELECT COUNT(*) \(base);", params: [.text(sinceISO)])
            )
        }
        let longTerm = "context IN (\(ReviewContext.newWord.rawValue), \(ReviewContext.review.rawValue))"
        return AccuracyReport(
            meaning: accuracy("quizType = \(QuizType.meaning.rawValue) AND \(longTerm)"),
            context: accuracy("quizType = \(QuizType.context.rawValue) AND \(longTerm)"),
            recall: accuracy("quizType = \(QuizType.recall.rawValue)"),
            sessionRetest: accuracy("context = \(ReviewContext.correction.rawValue) AND quizType IN (\(QuizType.meaning.rawValue), \(QuizType.context.rawValue))")
        )
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
        case null
    }

    private func bind(_ params: [SQLParam], to statement: OpaquePointer?) {
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
    }

    /// Runs a write statement.
    private func execute(_ query: String, params: [SQLParam]) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            bind(params, to: stmt)
            if sqlite3_step(stmt) != SQLITE_DONE {
                print("SQLite write error: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
    }

    /// Returns the first integer column of the first row (0 when there is none).
    private func countQuery(_ query: String, params: [SQLParam]) -> Int {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        var value = 0
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            bind(params, to: stmt)
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = Int(sqlite3_column_int(stmt, 0))
            }
        } else {
            print("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
        return value
    }

    private func executeQuery(query: String, params: [SQLParam] = []) -> [Corpus] {
        var list: [Corpus] = []
        guard let db = db else { return list }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            bind(params, to: statement)

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
    
    /// Review schedule of studied words for the dashboard. NEW words have no
    /// review date yet, so they are excluded instead of counting as overdue.
    func fetchScheduleDistribution(now: Date = Date()) -> ScheduleDistribution {
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
                SUM(CASE WHEN datetime(p.nextReviewAt) <= datetime(?1) THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(p.nextReviewAt) > datetime(?1) AND datetime(p.nextReviewAt) <= datetime(?1, '+3 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(p.nextReviewAt) > datetime(?1, '+3 days') AND datetime(p.nextReviewAt) <= datetime(?1, '+7 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(p.nextReviewAt) > datetime(?1, '+7 days') AND datetime(p.nextReviewAt) <= datetime(?1, '+30 days') THEN 1 ELSE 0 END),
                SUM(CASE WHEN datetime(p.nextReviewAt) > datetime(?1, '+30 days') THEN 1 ELSE 0 END)
            FROM WordProgress p JOIN Corpus c ON c.id = p.corpusId
            WHERE c.vocabularyId = ?2 AND c.isDeleted = 0;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            bind([.text(StudyClock.iso(now)), .text(unifiedVocabId)], to: stmt)
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
