import Foundation
import SQLite3

// Same transient-binding rule as in DatabaseManager.swift; the constant is
// file-scoped there, so it is declared again here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Spaced-repetition storage, session planning and learning statistics.
///
/// Everything here is **additive**: the existing `Corpus` columns keep their
/// meaning (`familiar` still drives 외운 단어 / 난공불락, `scheduledAt` is still
/// the review date), and the extra bookkeeping lives in two new tables that are
/// created on demand. An existing Documents database therefore keeps working —
/// on first launch after the update the tables are simply empty, which reads as
/// "nothing has been graded by the new engine yet".
extension DatabaseManager {

    // MARK: - Schema

    /// Creates the additive learning tables/indexes if they are missing.
    /// Safe to call on every launch, on both fresh and existing databases.
    func ensureLearningSchema() {
        guard let db = db else { return }

        let schemaSQL = """
            CREATE TABLE IF NOT EXISTS WordLearning (
                corpusId TEXT NOT NULL PRIMARY KEY,
                introducedAt TEXT,
                lastReviewedAt TEXT,
                reviewCount INTEGER NOT NULL DEFAULT 0,
                lapseCount INTEGER NOT NULL DEFAULT 0,
                intervalDays INTEGER NOT NULL DEFAULT 0,
                meaningCorrect INTEGER NOT NULL DEFAULT 0,
                meaningTotal INTEGER NOT NULL DEFAULT 0,
                contextCorrect INTEGER NOT NULL DEFAULT 0,
                contextTotal INTEGER NOT NULL DEFAULT 0,
                recallCorrect INTEGER NOT NULL DEFAULT 0,
                recallTotal INTEGER NOT NULL DEFAULT 0,
                updatedAt TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS ReviewLog (
                id TEXT NOT NULL PRIMARY KEY,
                corpusId TEXT NOT NULL,
                mode TEXT NOT NULL,
                isCorrect INTEGER NOT NULL,
                isCorrection INTEGER NOT NULL DEFAULT 0,
                familiarAfter INTEGER NOT NULL DEFAULT 0,
                reviewedAt TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_reviewlog_reviewedAt ON ReviewLog(reviewedAt);
            CREATE INDEX IF NOT EXISTS idx_reviewlog_corpusId ON ReviewLog(corpusId);
            CREATE INDEX IF NOT EXISTS idx_corpus_schedule ON Corpus(vocabularyId, isDeleted, scheduledAt);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schemaSQL, nil, nil, &errMsg) != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            print("Learning schema creation failed: \(message)")
        }
        sqlite3_free(errMsg)
    }

    // MARK: - Session planning

    /// Builds a session out of **due reviews plus new words** and nothing else.
    ///
    /// A word whose `scheduledAt` is still in the future is never selected, for
    /// any reason: there is no "fill the quota" fallback any more. If there are
    /// only 12 due words and 20 new ones, the session is 32 questions long.
    func fetchSessionPlan(config: SRSConfiguration = .default) -> StudySessionPlan {
        guard db != nil else { return .empty }

        let dueLimit = max(0, min(config.maxDuePerSession, config.maxSessionSize))
        var dueWords: [Corpus] = []
        if dueLimit > 0 {
            // Already graded at least once and the review date has arrived.
            let dueQuery = """
                SELECT c.id, c.vocabularyId, c.word, c.meaning, c.pos, c.pronunciation, c."desc", c.synonym,
                       c.antonym, c.image, c.familiar, c.isDeleted, c.scheduledAt, c.updatedAt, c.createdAt, c.exampleSentence
                FROM Corpus AS c
                JOIN WordLearning AS wl ON wl.corpusId = c.id AND wl.reviewCount > 0
                WHERE c.vocabularyId = ? AND c.isDeleted = 0
                  AND datetime(c.scheduledAt) <= datetime('now')
                ORDER BY datetime(c.scheduledAt) ASC
                LIMIT ?;
            """
            dueWords = executeQuery(query: dueQuery, params: [.text(unifiedVocabId), .integer(dueLimit)])
        }

        let remainingRoom = max(0, config.maxSessionSize - dueWords.count)
        let newLimit = min(config.newWordsPerSession, remainingRoom)
        var newWords: [Corpus] = []
        if newLimit > 0 {
            // Never graded by this engine. Weakest words first so anything the
            // legacy app already struggled with gets introduced early.
            let newQuery = """
                SELECT c.id, c.vocabularyId, c.word, c.meaning, c.pos, c.pronunciation, c."desc", c.synonym,
                       c.antonym, c.image, c.familiar, c.isDeleted, c.scheduledAt, c.updatedAt, c.createdAt, c.exampleSentence
                FROM Corpus AS c
                LEFT JOIN WordLearning AS wl ON wl.corpusId = c.id
                WHERE c.vocabularyId = ? AND c.isDeleted = 0
                  AND datetime(c.scheduledAt) <= datetime('now')
                  AND (wl.corpusId IS NULL OR wl.reviewCount = 0)
                ORDER BY c.familiar ASC, RANDOM()
                LIMIT ?;
            """
            newWords = executeQuery(query: newQuery, params: [.text(unifiedVocabId), .integer(newLimit)])
        }

        return StudySessionPlan(dueWords: dueWords, newWords: newWords)
    }

    /// How many words are waiting right now, for the dashboard to show before a
    /// session is started. Uses the same rules as `fetchSessionPlan`.
    func fetchAvailableCounts() -> (due: Int, new: Int) {
        let sql = """
            SELECT
                SUM(CASE WHEN introduced = 1 THEN 1 ELSE 0 END),
                SUM(CASE WHEN introduced = 0 THEN 1 ELSE 0 END)
            FROM (
                SELECT CASE WHEN wl.corpusId IS NOT NULL AND wl.reviewCount > 0 THEN 1 ELSE 0 END AS introduced
                FROM Corpus AS c
                LEFT JOIN WordLearning AS wl ON wl.corpusId = c.id
                WHERE c.vocabularyId = ? AND c.isDeleted = 0
                  AND datetime(c.scheduledAt) <= datetime('now')
            );
        """
        let values = fetchIntRow(sql: sql, params: [.text(unifiedVocabId)], columnCount: 2)
        return (due: values.first ?? 0, new: values.count > 1 ? values[1] : 0)
    }

    // MARK: - Recording answers

    /// Records one answer and applies the spaced-repetition consequences.
    ///
    /// - Parameters:
    ///   - isCorrection: `true` for answers given while fixing a mistake in the
    ///     same session (오답 타이핑 / 재퀴즈). Those never raise `familiar` and
    ///     never lengthen an interval — they are logged separately so
    ///     "today's correction" can never be read as "long-term retention".
    ///   - alreadyFailedThisSession: prevents a word from being pushed several
    ///     familiarity steps down inside a single sitting.
    @discardableResult
    func recordAnswer(
        corpusId: String,
        mode: StudyQuestionMode,
        isCorrect: Bool,
        isCorrection: Bool,
        alreadyFailedThisSession: Bool = false,
        now: Date = Date()
    ) -> ReviewGrade? {
        guard let db = db else { return nil }

        // 1. Current state. `isDue` is resolved by SQLite so the several date
        //    formats stored in the corpus never need parsing in Swift.
        var familiar = 0
        var isDue = true
        var hasRow = false
        let stateQuery = """
            SELECT familiar,
                   CASE WHEN scheduledAt IS NULL OR datetime(scheduledAt) <= datetime('now') THEN 1 ELSE 0 END
            FROM Corpus WHERE id = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, stateQuery, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, corpusId.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                familiar = Int(sqlite3_column_int(statement, 0))
                isDue = sqlite3_column_int(statement, 1) == 1
                hasRow = true
            }
        }
        sqlite3_finalize(statement)
        guard hasRow else { return nil }

        // 2. Apply the scheduling rules.
        let grade = SRSScheduler.grade(
            familiar: familiar,
            isDue: isDue,
            isCorrect: isCorrect,
            isCorrection: isCorrection,
            alreadyFailedThisSession: alreadyFailedThisSession,
            now: now
        )

        let formatter = ISO8601DateFormatter()
        let nowString = formatter.string(from: now)

        // 3. Write back to Corpus (legacy columns keep their meaning).
        if let scheduledAt = grade.scheduledAt {
            executeUpdate(
                sql: "UPDATE Corpus SET familiar = ?, scheduledAt = ?, updatedAt = ? WHERE id = ?;",
                params: [.integer(grade.familiar), .text(formatter.string(from: scheduledAt)), .text(nowString), .text(corpusId)]
            )
        } else {
            // Practised ahead of schedule — credit the answer, keep the date.
            executeUpdate(
                sql: "UPDATE Corpus SET familiar = ?, updatedAt = ? WHERE id = ?;",
                params: [.integer(grade.familiar), .text(nowString), .text(corpusId)]
            )
        }

        // 4. Per-word bookkeeping. Only graded reviews move the counters; a
        //    correction just refreshes `lastReviewedAt`.
        let graded = grade.countsAsGradedReview
        let meaningCorrect = (graded && mode == .meaning && isCorrect) ? 1 : 0
        let meaningTotal = (graded && mode == .meaning) ? 1 : 0
        let contextCorrect = (graded && mode == .context && isCorrect) ? 1 : 0
        let contextTotal = (graded && mode == .context) ? 1 : 0
        let recallCorrect = (graded && mode == .recall && isCorrect) ? 1 : 0
        let recallTotal = (graded && mode == .recall) ? 1 : 0

        let upsert = """
            INSERT INTO WordLearning
                (corpusId, introducedAt, lastReviewedAt, reviewCount, lapseCount, intervalDays,
                 meaningCorrect, meaningTotal, contextCorrect, contextTotal, recallCorrect, recallTotal, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(corpusId) DO UPDATE SET
                introducedAt = COALESCE(WordLearning.introducedAt, excluded.introducedAt),
                lastReviewedAt = excluded.lastReviewedAt,
                reviewCount = WordLearning.reviewCount + excluded.reviewCount,
                lapseCount = WordLearning.lapseCount + excluded.lapseCount,
                intervalDays = CASE WHEN excluded.intervalDays > 0 THEN excluded.intervalDays ELSE WordLearning.intervalDays END,
                meaningCorrect = WordLearning.meaningCorrect + excluded.meaningCorrect,
                meaningTotal = WordLearning.meaningTotal + excluded.meaningTotal,
                contextCorrect = WordLearning.contextCorrect + excluded.contextCorrect,
                contextTotal = WordLearning.contextTotal + excluded.contextTotal,
                recallCorrect = WordLearning.recallCorrect + excluded.recallCorrect,
                recallTotal = WordLearning.recallTotal + excluded.recallTotal,
                updatedAt = excluded.updatedAt;
        """
        executeUpdate(sql: upsert, params: [
            .text(corpusId),
            graded ? .text(nowString) : .null,
            .text(nowString),
            .integer(graded ? 1 : 0),
            .integer(grade.isLapse ? 1 : 0),
            .integer(grade.intervalDays),
            .integer(meaningCorrect),
            .integer(meaningTotal),
            .integer(contextCorrect),
            .integer(contextTotal),
            .integer(recallCorrect),
            .integer(recallTotal),
            .text(nowString)
        ])

        // 5. Event log — the source for the dashboard's accuracy panels.
        executeUpdate(
            sql: """
                INSERT INTO ReviewLog (id, corpusId, mode, isCorrect, isCorrection, familiarAfter, reviewedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            params: [
                .text(UUID().uuidString.lowercased()),
                .text(corpusId),
                .text(mode.rawValue),
                .integer(isCorrect ? 1 : 0),
                .integer(isCorrection ? 1 : 0),
                .integer(grade.familiar),
                .text(nowString)
            ]
        )

        updateVocabularyStatistics()
        return grade
    }

    // MARK: - Statistics

    /// NEW / LEARNING / DUE / MASTERED across the whole vocabulary.
    ///
    /// MASTERED additionally requires `deep = 1`: at least one correct answer
    /// in a harder format (sentence blank or typed spelling). Recognising a
    /// gloss among four options repeatedly is not, on its own, mastery.
    func fetchLearningStateCounts() -> LearningStateCounts {
        let sql = """
            SELECT
                SUM(CASE WHEN isDue = 1 AND introduced = 0 THEN 1 ELSE 0 END),
                SUM(CASE WHEN isDue = 0 AND NOT (familiar >= ? AND deep = 1) THEN 1 ELSE 0 END),
                SUM(CASE WHEN isDue = 1 AND introduced = 1 THEN 1 ELSE 0 END),
                SUM(CASE WHEN isDue = 0 AND familiar >= ? AND deep = 1 THEN 1 ELSE 0 END)
            FROM (
                SELECT c.familiar AS familiar,
                       CASE WHEN c.scheduledAt IS NULL OR datetime(c.scheduledAt) <= datetime('now') THEN 1 ELSE 0 END AS isDue,
                       CASE WHEN wl.corpusId IS NOT NULL AND wl.reviewCount > 0 THEN 1 ELSE 0 END AS introduced,
                       CASE WHEN COALESCE(wl.contextCorrect, 0) + COALESCE(wl.recallCorrect, 0) > 0 THEN 1 ELSE 0 END AS deep
                FROM Corpus AS c
                LEFT JOIN WordLearning AS wl ON wl.corpusId = c.id
                WHERE c.vocabularyId = ? AND c.isDeleted = 0
            );
        """
        let threshold = SRSScheduler.masteredFamiliarThreshold
        let values = fetchIntRow(
            sql: sql,
            params: [.integer(threshold), .integer(threshold), .text(unifiedVocabId)],
            columnCount: 4
        )
        guard values.count == 4 else { return .zero }
        return LearningStateCounts(new: values[0], learning: values[1], due: values[2], mastered: values[3])
    }

    /// Today's activity. Graded reviews and same-session corrections are kept
    /// in separate fields on purpose.
    func fetchTodaySummary(now: Date = Date(), calendar: Calendar = .current) -> TodayStudySummary {
        let startOfDay = ISO8601DateFormatter().string(from: calendar.startOfDay(for: now))
        var summary = TodayStudySummary()

        let introduced = fetchIntRow(
            sql: "SELECT COUNT(*) FROM WordLearning WHERE introducedAt IS NOT NULL AND datetime(introducedAt) >= datetime(?);",
            params: [.text(startOfDay)],
            columnCount: 1
        )
        summary.newIntroduced = introduced.first ?? 0

        let graded = fetchIntRow(
            sql: """
                SELECT COUNT(*), COALESCE(SUM(isCorrect), 0)
                FROM ReviewLog
                WHERE isCorrection = 0 AND datetime(reviewedAt) >= datetime(?);
            """,
            params: [.text(startOfDay)],
            columnCount: 2
        )
        if graded.count == 2 {
            summary.reviewSuccess = graded[1]
            summary.reviewFail = max(0, graded[0] - graded[1])
        }

        // Graded answers today on words that were introduced on an earlier day —
        // i.e. actual spaced reviews rather than first exposures.
        let dueReviewed = fetchIntRow(
            sql: """
                SELECT COUNT(*)
                FROM ReviewLog AS r
                JOIN WordLearning AS wl ON wl.corpusId = r.corpusId
                WHERE r.isCorrection = 0
                  AND datetime(r.reviewedAt) >= datetime(?)
                  AND wl.introducedAt IS NOT NULL
                  AND datetime(wl.introducedAt) < datetime(?);
            """,
            params: [.text(startOfDay), .text(startOfDay)],
            columnCount: 1
        )
        summary.dueReviewed = dueReviewed.first ?? 0

        let corrections = fetchIntRow(
            sql: """
                SELECT COUNT(*), COALESCE(SUM(isCorrect), 0)
                FROM ReviewLog
                WHERE isCorrection = 1 AND datetime(reviewedAt) >= datetime(?);
            """,
            params: [.text(startOfDay)],
            columnCount: 2
        )
        if corrections.count == 2 {
            summary.correctionAttempts = corrections[0]
            summary.correctionSuccess = corrections[1]
        }

        return summary
    }

    /// Accuracy per question type over the last `days` days.
    ///
    /// Only graded answers are counted. Same-session correction attempts are
    /// returned separately (`correctionCorrect`/`correctionTotal`) because
    /// mixing them in would flatter the numbers — re-answering a word two
    /// minutes after being shown it says nothing about retention.
    func fetchRecentPerformance(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> RecentPerformance {
        guard let db = db else { return .empty }

        let start = calendar.date(byAdding: .day, value: -max(1, days) + 1, to: calendar.startOfDay(for: now)) ?? now
        let startString = ISO8601DateFormatter().string(from: start)

        var totals: [StudyQuestionMode: (correct: Int, total: Int)] = [:]
        let sql = """
            SELECT mode, COUNT(*), COALESCE(SUM(isCorrect), 0)
            FROM ReviewLog
            WHERE isCorrection = 0 AND datetime(reviewedAt) >= datetime(?)
            GROUP BY mode;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, startString.cString(using: .utf8), -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let modeText = sqlite3_column_text(statement, 0),
                      let mode = StudyQuestionMode(rawValue: String(cString: modeText)) else { continue }
                totals[mode] = (correct: Int(sqlite3_column_int(statement, 2)), total: Int(sqlite3_column_int(statement, 1)))
            }
        }
        sqlite3_finalize(statement)

        var performance = RecentPerformance()
        performance.modeAccuracies = StudyQuestionMode.allCases.map { mode in
            let entry = totals[mode] ?? (correct: 0, total: 0)
            return ModeAccuracy(mode: mode, correct: entry.correct, total: entry.total)
        }

        let corrections = fetchIntRow(
            sql: """
                SELECT COUNT(*), COALESCE(SUM(isCorrect), 0)
                FROM ReviewLog
                WHERE isCorrection = 1 AND datetime(reviewedAt) >= datetime(?);
            """,
            params: [.text(startString)],
            columnCount: 2
        )
        if corrections.count == 2 {
            performance.correctionTotal = corrections[0]
            performance.correctionCorrect = corrections[1]
        }
        return performance
    }

    // MARK: - Small SQL helpers

    /// Runs a statement that returns a single row of integers.
    func fetchIntRow(sql: String, params: [SQLParam], columnCount: Int) -> [Int] {
        guard let db = db, columnCount > 0 else { return [] }
        var values: [Int] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind(params: params, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                for column in 0..<columnCount {
                    values.append(Int(sqlite3_column_int(statement, Int32(column))))
                }
            }
        } else {
            print("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
        return values
    }

    /// Runs an INSERT/UPDATE/DELETE statement.
    func executeUpdate(sql: String, params: [SQLParam]) {
        guard let db = db else { return }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind(params: params, to: statement)
            if sqlite3_step(statement) != SQLITE_DONE {
                print("SQLite update failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("SQLite prepare error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
    }

    private func bind(params: [SQLParam], to statement: OpaquePointer?) {
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
}
