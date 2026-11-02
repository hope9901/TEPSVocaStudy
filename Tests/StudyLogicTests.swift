import XCTest
import SQLite3
@testable import TEPSVocaStudy

/// Exercises the real SQLite schema, migrations and SRS rules against a
/// temporary copy of the bundled vocabulary DB (the user's data is never touched).
final class StudyLogicTests: XCTestCase {
    private var tempDir: URL!
    private let calendar = Calendar.current

    /// Day 0, 10:00 local time.
    private lazy var day0: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 10))!
    }()

    private func day(_ offset: Int, hour: Int = 10) -> Date {
        let start = calendar.startOfDay(for: day0)
        return calendar.date(byAdding: DateComponents(day: offset, hour: hour), to: start)!
    }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var bundledDB: URL {
        Bundle.main.url(forResource: "v85_20260312T133124Z", withExtension: "db")!
    }

    private func makeDatabase(at url: URL? = nil) -> DatabaseManager {
        let path = url ?? tempDir.appendingPathComponent("test.db")
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        return DatabaseManager(databaseURL: path, bundledURL: bundledDB, defaults: defaults)
    }

    private func sql(_ dbURL: URL, _ statement: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, statement, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
        sqlite3_free(err)
        sqlite3_close(handle)
    }

    private func scalar(_ dbURL: URL, _ query: String) -> String? {
        var handle: OpaquePointer?
        sqlite3_open(dbURL.path, &handle)
        var stmt: OpaquePointer?
        var value: String?
        if sqlite3_prepare_v2(handle, query, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            value = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(handle)
        return value
    }

    // MARK: - TEST A: a word answered today is never re-served as filler today

    func testA_wordScheduledForFutureIsNotFillerOnSameDay() {
        let db = makeDatabase()
        let planner = SessionPlanner(database: db)

        let first = planner.plan(mode: .meaning, dailyNewLimit: 20, now: day0)
        XCTAssertEqual(first.dueCount, 0, "fresh install: nothing has an in-app review date yet")
        XCTAssertEqual(first.items.count, 20, "session = new-word quota, not padded to 100")

        // Answer every word of the first session correctly.
        for item in first.items {
            db.recordFirstAnswer(corpusId: item.corpus.id, quizType: .meaning, correct: true, now: day0)
        }
        let studied = Set(first.items.map(\.corpus.id))
        let progress = db.fetchProgress(corpusId: first.items[0].corpus.id)!
        XCTAssertGreaterThan(progress.nextReviewAt, StudyClock.iso(day0), "next review is in the future")

        // Same day, several more sessions: quota is used up and nothing is padded.
        for hour in [11, 15, 22] {
            let again = planner.plan(mode: .meaning, dailyNewLimit: 20, now: day(0, hour: hour))
            XCTAssertTrue(again.items.isEmpty, "no filler words once due + new are exhausted (hour \(hour))")
        }
        // Even an explicit "more new words" request only brings NEW words.
        let extra = planner.plan(mode: .meaning, dailyNewLimit: 20, extraNewWords: 30, now: day(0, hour: 23))
        XCTAssertEqual(extra.items.count, 30)
        XCTAssertTrue(Set(extra.items.map(\.corpus.id)).isDisjoint(with: studied))
        XCTAssertTrue(extra.items.allSatisfy { $0.origin == .newWord })

        // Context mode follows the same selection rules.
        let context = planner.plan(mode: .context, dailyNewLimit: 20, now: day(0, hour: 23))
        XCTAssertTrue(context.items.isEmpty)
    }

    // MARK: - TEST B: same-session correction never counts as long-term success

    func testB_correctionDoesNotPromote() {
        let db = makeDatabase()
        let word = db.fetchNewWords(limit: 1)[0]
        let familiarBefore = word.familiar

        let context = db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: false, now: day0)
        XCTAssertEqual(context, .newWord)
        let afterMiss = db.fetchProgress(corpusId: word.id)!
        XCTAssertEqual(afterMiss.state, .learning)
        XCTAssertEqual(afterMiss.intervalDays, 1)
        XCTAssertEqual(afterMiss.nextReviewAt, StudyClock.iso(calendar.startOfDay(for: day(1))), "next check is tomorrow")

        // Typing + re-quiz succeed later the same session.
        db.recordCorrection(corpusId: word.id, quizType: .recall, correct: true, now: day0)
        db.recordCorrection(corpusId: word.id, quizType: .meaning, correct: true, now: day0)
        db.recordCorrection(corpusId: word.id, quizType: .meaning, correct: true, now: day0)

        XCTAssertEqual(db.fetchProgress(corpusId: word.id), afterMiss, "schedule and counters unchanged by corrections")
        let reloaded = db.fetchAllActiveWords().first { $0.id == word.id }!
        XCTAssertEqual(reloaded.familiar, familiarBefore - 1, "familiar moves once per session, on the first answer")

        let report = db.fetchAccuracyReport(now: day0)
        XCTAssertEqual(report.meaning, Accuracy(correct: 0, total: 1), "SRS accuracy only sees the first attempt")
        XCTAssertEqual(report.sessionRetest, Accuracy(correct: 2, total: 2), "re-quiz is reported separately")
        XCTAssertEqual(report.recall, Accuracy(correct: 1, total: 1))
    }

    /// Full view-model flow: wrong → typing → re-quiz correct (also TEST G).
    func testB_G_viewModelQuizTypingReQuizFlow() {
        let db = makeDatabase()
        let vm = QuizSessionViewModel(database: db)
        vm.startSession(mode: .meaning, now: day0)
        XCTAssertEqual(vm.phase, .mainQuiz)
        XCTAssertFalse(vm.currentItems.isEmpty)
        XCTAssertEqual(vm.options.count, 4, "meaning quiz still has 4 options")

        let missed = vm.currentItem!
        let wrongOption = vm.options.first { $0.corpusId != missed.corpus.id }!
        vm.submitAnswer(option: wrongOption, now: day0)
        XCTAssertEqual(vm.isCorrect, false)
        let progressAfterMiss = db.fetchProgress(corpusId: missed.corpus.id)

        // Answer the rest correctly.
        vm.nextQuestion()
        while vm.phase == .mainQuiz {
            let right = vm.options.first { $0.corpusId == vm.currentItem!.corpus.id }!
            vm.submitAnswer(option: right, now: day0)
            vm.nextQuestion()
        }
        XCTAssertEqual(vm.phase, .typingReview)
        XCTAssertEqual(vm.currentTypingWord?.id, missed.corpus.id)

        // Blind typing without hints → recall success, then re-quiz.
        vm.typingMode = .blindMode
        vm.submitTypingInput(missed.corpus.word.uppercased())
        let advanced = expectation(description: "typing advances to re-quiz")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { advanced.fulfill() }
        wait(for: [advanced], timeout: 3)
        XCTAssertEqual(vm.phase, .reQuiz)

        let right = vm.options.first { $0.corpusId == missed.corpus.id }!
        vm.submitAnswer(option: right, now: day0)
        vm.nextQuestion()
        XCTAssertEqual(vm.phase, .finished)

        XCTAssertEqual(db.fetchProgress(corpusId: missed.corpus.id), progressAfterMiss,
                       "re-quiz success leaves the word scheduled for tomorrow")
        XCTAssertEqual(vm.summary.corrected, 1)
        XCTAssertEqual(vm.summary.firstAttemptTotal, vm.totalSessionWordsCount)
        XCTAssertEqual(vm.summary.firstAttemptCorrect, vm.totalSessionWordsCount - 1)
    }

    // MARK: - TEST C: the word comes back once its review day arrives

    func testC_wordReturnsWhenDue() {
        let db = makeDatabase()
        let planner = SessionPlanner(database: db)
        let word = db.fetchNewWords(limit: 1)[0]
        db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: true, now: day0)

        XCTAssertFalse(db.fetchDueWords(now: day(0, hour: 23), limit: 100).contains { $0.id == word.id })
        XCTAssertTrue(db.fetchDueWords(now: day(1, hour: 0), limit: 100).contains { $0.id == word.id },
                      "due from local midnight of the next day")

        let plan = planner.plan(mode: .meaning, dailyNewLimit: 0, now: day(1))
        XCTAssertEqual(plan.items.map(\.corpus.id), [word.id])
        XCTAssertEqual(plan.items.first?.origin, .review)

        // A spaced success on day 1 → 3 days; streak continues 7, 14…
        db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: true, now: day(1))
        var progress = db.fetchProgress(corpusId: word.id)!
        XCTAssertEqual(progress.intervalDays, 3)
        XCTAssertEqual(progress.state, .review)
        XCTAssertTrue(db.fetchDueWords(now: day(3), limit: 100).isEmpty)
        XCTAssertEqual(db.fetchDueWords(now: day(4, hour: 0), limit: 100).map(\.id), [word.id])

        db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: true, now: day(4))
        db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: true, now: day(11))
        progress = db.fetchProgress(corpusId: word.id)!
        XCTAssertEqual(progress.intervalDays, 14)
        XCTAssertEqual(progress.state, .review, "meaning recognition alone never reaches MASTERED")

        db.recordFirstAnswer(corpusId: word.id, quizType: .context, correct: true, now: day(25))
        progress = db.fetchProgress(corpusId: word.id)!
        XCTAssertEqual(progress.intervalDays, 30)
        XCTAssertEqual(progress.state, .mastered, "long interval + context evidence")

        // A lapse resets to tomorrow and counts.
        db.recordFirstAnswer(corpusId: word.id, quizType: .context, correct: false, now: day(55))
        progress = db.fetchProgress(corpusId: word.id)!
        XCTAssertEqual(progress.state, .learning)
        XCTAssertEqual(progress.intervalDays, 1)
        XCTAssertEqual(progress.lapses, 1)
    }

    // MARK: - TEST D: context questions

    func testD_contextBlankingHandlesInflectionsAndPhrases() {
        XCTAssertEqual(ContextBlanker.blanked("emerge", in: "New evidence emerged, challenging the assumptions."),
                       "New evidence ______, challenging the assumptions.")
        XCTAssertEqual(ContextBlanker.blanked("begin", in: "The truck Began to careen."), "The truck ______ to careen.")
        XCTAssertEqual(ContextBlanker.blanked("Abate", in: "The storm finally began to abate after midnight."),
                       "The storm finally began to ______ after midnight.")
        XCTAssertEqual(ContextBlanker.blanked("take ~ back", in: "Customers can take defective items back within 30 days."),
                       "Customers can ______ defective items ______ within 30 days.")
        XCTAssertEqual(ContextBlanker.blanked("slip one’s mind", in: "The deadline completely slipped my mind."),
                       "The deadline completely ______.")
        XCTAssertNil(ContextBlanker.blanked("harass", in: "The company has a policy against workplace harassment."),
                     "a derived noun is not the target word — no fabricated blank")
    }

    func testD_contextSessionUsesBlanksAndPlausibleDistractors() {
        let db = makeDatabase()
        let pool = db.fetchAllActiveWords()
        let service = DistractorService(pool: pool)
        let planner = SessionPlanner(database: db)

        var blanked = 0, posMatches = 0, distractorTotal = 0
        for corpus in pool.shuffled().prefix(150) {
            let item = planner.makeItem(corpus, origin: .newWord, preferred: .context)
            guard item.quizType == .context, let sentence = item.blankedSentence else {
                XCTAssertNil(ContextBlanker.blanked(corpus.word, in: corpus.exampleSentence ?? ""),
                             "only words absent from their example fall back to meaning")
                continue
            }
            blanked += 1
            XCTAssertTrue(sentence.contains(ContextBlanker.blank))
            XCTAssertFalse(ContextBlanker.contains(corpus.word, in: sentence), "target removed: \(corpus.word)")

            let wrong = service.contextDistractors(for: corpus, blankedSentence: sentence, count: 3)
            XCTAssertEqual(wrong.count, 3)
            XCTAssertFalse(wrong.contains { $0.id == corpus.id }, "the answer is not also a distractor")
            let target = service.features(for: corpus)
            for d in wrong {
                let f = service.features(for: d)
                XCTAssertEqual(f.tokenCount > 1, target.tokenCount > 1, "same shape: \(corpus.word) vs \(d.word)")
                distractorTotal += 1
                if f.pos == target.pos { posMatches += 1 }
            }
        }
        XCTAssertGreaterThan(blanked, 130, "≈98% of words have their headword in the example")
        XCTAssertGreaterThan(Double(posMatches) / Double(distractorTotal), 0.9, "distractors share the part of speech")
    }

    func testD_contextViewModelIncludesAnswerAmongOptions() {
        let db = makeDatabase()
        let vm = QuizSessionViewModel(database: db)
        vm.startSession(mode: .context, now: day0)
        let contextItems = vm.currentItems.filter { $0.quizType == .context }
        XCTAssertFalse(contextItems.isEmpty)
        for _ in 0..<min(10, vm.currentItems.count) {
            let item = vm.currentItem!
            XCTAssertEqual(vm.options.filter { $0.corpusId == item.corpus.id }.count, 1)
            XCTAssertEqual(vm.options.count, 4)
            if item.quizType == .context {
                XCTAssertNotNil(item.blankedSentence)
            }
            vm.submitAnswer(option: vm.options.first { $0.corpusId == item.corpus.id }!, now: day0)
            vm.nextQuestion()
        }
    }

    // MARK: - TEST E: existing installs migrate without losing progress

    func testE_existingUserDataMigrates() throws {
        // Simulate a pre-update install: bundled DB + rows studied by the old app.
        let legacyURL = tempDir.appendingPathComponent("legacy.db")
        try FileManager.default.copyItem(at: bundledDB, to: legacyURL)
        let ids = (0..<4).compactMap { offset in
            scalar(legacyURL, "SELECT id FROM Corpus WHERE vocabularyId='unified-teps-vocab-id' AND isDeleted=0 ORDER BY id LIMIT 1 OFFSET \(offset);")
        }
        sql(legacyURL, """
            UPDATE Corpus SET familiar = 3, scheduledAt = '2026-10-05T09:00:00Z' WHERE id = '\(ids[0])';
            UPDATE Corpus SET familiar = 0, scheduledAt = '2026-09-30T08:00:00Z' WHERE id = '\(ids[1])';
            UPDATE Corpus SET familiar = 5, scheduledAt = '2026-11-01T09:00:00Z' WHERE id = '\(ids[2])';
            INSERT INTO Corpus (id, vocabularyId, word, meaning, familiar, isDeleted, scheduledAt, updatedAt, createdAt, exampleSentence)
            VALUES ('user-word', 'unified-teps-vocab-id', 'zyzzyva', '바구미', 0, 0,
                    '2026-09-20T01:00:00Z', '2026-09-20T01:00:00Z', '2026-09-20T01:00:00Z', '');
        """)

        let db = makeDatabase(at: legacyURL)
        XCTAssertEqual(scalar(legacyURL, "SELECT value FROM StudyMeta WHERE key = 'learningSchemaVersion';"), "1")
        XCTAssertEqual(scalar(legacyURL, "PRAGMA user_version;"), "85", "the original app's schema version is left alone")

        let p0 = try XCTUnwrap(db.fetchProgress(corpusId: ids[0]))
        XCTAssertEqual(p0.intervalDays, 7)
        XCTAssertEqual(p0.reviewStreak, 2)
        XCTAssertEqual(p0.state, .review)
        XCTAssertEqual(p0.nextReviewAt, "2026-10-05T09:00:00Z", "review date preserved")

        let p1 = try XCTUnwrap(db.fetchProgress(corpusId: ids[1]))
        XCTAssertEqual(p1.state, .learning)
        XCTAssertEqual(p1.intervalDays, 1)

        XCTAssertEqual(db.fetchProgress(corpusId: ids[2])?.intervalDays, 30)
        XCTAssertNil(db.fetchProgress(corpusId: ids[3]), "never studied in this app → NEW")
        XCTAssertNil(db.fetchProgress(corpusId: "user-word"), "user-added but unanswered → NEW")

        let states = db.fetchStateCounts(now: day0)
        XCTAssertEqual(states.due, 1, "only the overdue studied word is due")
        XCTAssertEqual(states.learning, 2)
        XCTAssertEqual(states.new, db.fetchAllActiveWords().count - 3)

        // Re-opening is idempotent.
        _ = makeDatabase(at: legacyURL)
        XCTAssertEqual(scalar(legacyURL, "SELECT COUNT(*) FROM WordProgress;"), "3")
    }

    /// An install still on content v3 picks up the v4 headword fixes and keeps its progress.
    func testE_contentV4FixesReachExistingInstalls() throws {
        let legacyURL = tempDir.appendingPathComponent("v3.db")
        try FileManager.default.copyItem(at: bundledDB, to: legacyURL)
        let id = "11f0-cc5e-20acc0f0-ab32-47ec56f920d8"
        sql(legacyURL, "UPDATE Corpus SET word = 'casual', familiar = 2, scheduledAt = '2026-10-03T00:00:00Z' WHERE id = '\(id)';")

        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        defaults.set(3, forKey: "bundledContentVersion")
        let db = DatabaseManager(databaseURL: legacyURL, bundledURL: bundledDB, defaults: defaults)

        XCTAssertEqual(scalar(legacyURL, "SELECT word FROM Corpus WHERE id = '\(id)';"), "causal")
        XCTAssertEqual(scalar(legacyURL, "SELECT familiar FROM Corpus WHERE id = '\(id)';"), "2")
        XCTAssertEqual(db.fetchProgress(corpusId: id)?.nextReviewAt, "2026-10-03T00:00:00Z")
        XCTAssertEqual(defaults.integer(forKey: "bundledContentVersion"), 6)
    }

    /// Every example sentence has a Korean translation, and an install on content v4
    /// (no translations table yet) receives them on upgrade without losing progress.
    func testE_exampleTranslationsShipAndSyncToExistingInstalls() throws {
        let fresh = makeDatabase()
        let words = fresh.fetchAllActiveWords().filter { !($0.exampleSentence ?? "").isEmpty }
        let translations = fresh.fetchExampleTranslations()
        XCTAssertEqual(words.filter { translations[$0.id] == nil }.map(\.word), [])

        let legacyURL = tempDir.appendingPathComponent("v4.db")
        try FileManager.default.copyItem(at: bundledDB, to: legacyURL)
        let id = try XCTUnwrap(words.first { $0.word == "uphold" }?.id)
        sql(legacyURL, """
            DROP TABLE ExampleTranslation;
            UPDATE Corpus SET familiar = 3, scheduledAt = '2026-11-03T00:00:00Z' WHERE id = '\(id)';
        """)
        let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
        defaults.set(4, forKey: "bundledContentVersion")
        let upgraded = DatabaseManager(databaseURL: legacyURL, bundledURL: bundledDB, defaults: defaults)

        XCTAssertEqual(upgraded.fetchExampleTranslations()[id], "법원은 강력한 판례를 근거로 이전 판결을 유지하기로 했다.")
        XCTAssertEqual(upgraded.fetchExampleTranslations().count, translations.count)
        XCTAssertEqual(upgraded.fetchProgress(corpusId: id)?.nextReviewAt, "2026-11-03T00:00:00Z")
        XCTAssertEqual(defaults.integer(forKey: "bundledContentVersion"), 6)
    }

    /// Content v6 cleaned example sentences: no duplicated phrases, correct verb
    /// forms, and each repaired word now produces exactly one blank.
    func testD_cleanedExamplesProduceSingleBlanks() throws {
        let db = makeDatabase()
        let words = db.fetchAllActiveWords()
        let duplicated = words.filter {
            ($0.exampleSentence ?? "").range(of: "\\b((?:[A-Za-z'’]+ ){1,3}[A-Za-z'’]+) \\1\\b",
                                             options: [.regularExpression, .caseInsensitive]) != nil
        }
        XCTAssertEqual(duplicated.map(\.word), [])

        let repaired = ["palm off", "hedge against", "stave off", "back away from", "hedge in", "foist off on",
                        "impute to", "wrest from", "inundate", "embellish", "relegate", "divulge", "beleaguer",
                        "fare", "harass", "legitimate", "attain", "erode", "planet", "make way"]
        for word in repaired {
            let corpus = try XCTUnwrap(words.first { $0.word == word }, word)
            let blanked = try XCTUnwrap(ContextBlanker.blanked(word, in: corpus.exampleSentence ?? ""), word)
            XCTAssertEqual(blanked.components(separatedBy: ContextBlanker.blank).count - 1, 1, "\(word): \(blanked)")
        }
        XCTAssertNil(words.first { $0.word == "make away" })
    }

    func testD_contextQuestionHasTranslationAfterAnswer() {
        let db = makeDatabase()
        let vm = QuizSessionViewModel(database: db)
        vm.startSession(mode: .context, now: day0)
        let item = try! XCTUnwrap(vm.currentItems.first { $0.quizType == .context })
        let translation = vm.exampleTranslation(for: item.corpus)
        XCTAssertNotNil(translation)
        XCTAssertTrue(translation!.range(of: "[가-힣]", options: .regularExpression) != nil)
    }

    // MARK: - TEST F: hard-word drill keeps working

    func testF_hardWordDrill() throws {
        let dbURL = tempDir.appendingPathComponent("hard.db")
        let db = makeDatabase(at: dbURL)
        let words = db.fetchNewWords(limit: 3)
        for word in words {
            db.recordFirstAnswer(corpusId: word.id, quizType: .meaning, correct: false, now: day0)
        }
        let ids = words.map { "'\($0.id)'" }.joined(separator: ",")
        sql(dbURL, "UPDATE Corpus SET familiar = -3 WHERE id IN (\(ids));")
        XCTAssertEqual(db.fetchStatistics().hard, 3)

        let plan = SessionPlanner(database: db).plan(mode: .hardWords, dailyNewLimit: 20, now: day(0, hour: 18))
        XCTAssertEqual(Set(plan.items.map(\.corpus.id)), Set(words.map(\.id)))
        XCTAssertTrue(plan.items.allSatisfy { $0.origin == .drill && $0.quizType == .meaning })

        let target = words[0]
        let before = try XCTUnwrap(db.fetchProgress(corpusId: target.id))
        let context = db.recordFirstAnswer(corpusId: target.id, quizType: .meaning, correct: true, now: day(0, hour: 18))
        XCTAssertEqual(context, .drill)
        XCTAssertEqual(db.fetchProgress(corpusId: target.id), before, "drill does not reschedule a not-yet-due word")
        XCTAssertEqual(db.fetchStatistics().hard, 2, "a correct drill answer still lifts familiar above -3")
    }

    // MARK: - Scheduler rules

    func testSchedulerFirstExposureIsOnlyANextDayCheck() {
        let outcome = SRSScheduler.apply(existing: nil, corpusId: "x", familiar: 0, quizType: .meaning, correct: true, now: day0)
        XCTAssertEqual(outcome.progress.intervalDays, 1)
        XCTAssertEqual(outcome.progress.reviewStreak, 0, "a first-day correct answer may be a guess")
        XCTAssertEqual(outcome.progress.state, .learning)
        XCTAssertEqual(outcome.familiar, 1)
    }

    func testPartOfSpeechInference() {
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("보장하다"), .verb)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("편리한"), .adjective)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("일시적인"), .adjective)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("정중히"), .adverb)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("판"), .noun)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("의견"), .noun)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("원인"), .noun)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("~에 관계없이"), .adverb)
        XCTAssertEqual(WordFeatures.inferPartOfSpeech("의도적으로"), .adverb)
    }

    /// "regardless of" used to get noun phrases (drug overdose, sharp dresser) that
    /// could never fill an adverbial blank; options must now be adverbial phrases.
    func testD_phraseDistractorsMatchGrammaticalRole() throws {
        let db = makeDatabase()
        let pool = db.fetchAllActiveWords()
        let service = DistractorService(pool: pool)
        let target = try XCTUnwrap(pool.first { $0.word == "regardless of" })
        XCTAssertEqual(service.features(for: target).pos, .adverb)
        let sentence = try XCTUnwrap(ContextBlanker.blanked(target.word, in: target.exampleSentence ?? ""))
        for _ in 0..<10 {
            let wrong = service.contextDistractors(for: target, blankedSentence: sentence, count: 3)
            XCTAssertEqual(wrong.count, 3)
            XCTAssertTrue(wrong.allSatisfy { $0.word.contains(" ") }, "phrase options for a phrase target")
            XCTAssertTrue(wrong.allSatisfy { service.features(for: $0).pos == .adverb }, "\(wrong.map(\.word))")
        }
    }
}
