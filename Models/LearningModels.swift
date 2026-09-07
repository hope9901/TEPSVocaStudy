import Foundation

// Types shared by the spaced-repetition scheduler, the database layer and the
// quiz session. Kept free of SQLite/SwiftUI so the learning rules stay testable
// on their own.

// MARK: - Question Types

/// What skill a single question actually tests.
/// Recognition (picking from options) and recall (producing the spelling) are
/// tracked separately because an app that only ever asks for recognition
/// overstates how well a word is really known.
enum StudyQuestionMode: String, CaseIterable, Codable {
    /// English word shown, pick the Korean meaning. (기존 기본 퀴즈)
    case meaning
    /// Sentence with a blank shown, pick the English word that fits. (TEPS Context Mode)
    case context
    /// Meaning / audio / context shown, type the English spelling.
    case recall

    var displayName: String {
        switch self {
        case .meaning: return "의미 인지"
        case .context: return "문맥 추론"
        case .recall: return "스펠링 재생"
        }
    }
}

/// Which question types a session is allowed to ask.
enum StudyMode: String, CaseIterable, Codable {
    /// Picks the question type per word based on how mature the word is.
    case mixed
    /// Only English → Korean meaning questions (the classic session).
    case meaningOnly
    /// Only sentence-blank questions; words without a usable example fall back
    /// to a meaning question rather than being dropped from the session.
    case contextOnly

    var displayName: String {
        switch self {
        case .mixed: return "혼합"
        case .meaningOnly: return "의미"
        case .contextOnly: return "문맥"
        }
    }
}

// MARK: - Word Learning State

/// Coarse lifecycle state of a word. This is the single definition of the four
/// states; `DatabaseManager.fetchLearningStateCounts()` computes them in one
/// aggregate query using exactly these rules:
///
/// * `new` — review date has arrived and the word has never been graded.
/// * `due` — review date has arrived and the word has been graded before.
/// * `learning` — review date is still in the future, mastery not established.
/// * `mastered` — review date is in the future, `familiar` is at the mastery
///   threshold **and** the word has been answered correctly in a harder format
///   than four-option recognition (sentence blank or typed spelling).
///
/// Only `new` and `due` words are ever put into a session.
enum WordLearningState: String, CaseIterable, Codable {
    case new
    case learning
    case due
    case mastered

    /// Short badge used on the dashboard.
    var badge: String { rawValue.uppercased() }
}

// MARK: - Session Planning

/// How a session is allowed to be sized. A session is `due + new`; it is never
/// padded with words whose review date has not arrived.
struct SRSConfiguration {
    /// Upper bound on how many due reviews a single session may contain.
    var maxDuePerSession: Int = 100
    /// Upper bound on how many brand-new words a single session introduces.
    var newWordsPerSession: Int = 20
    /// Hard cap on the whole session (due + new).
    var maxSessionSize: Int = 120

    static let `default` = SRSConfiguration()

    static func withNewWordLimit(_ limit: Int) -> SRSConfiguration {
        var config = SRSConfiguration.default
        config.newWordsPerSession = max(0, limit)
        return config
    }
}

/// The words a session will actually study, with due reviews and newly
/// introduced words kept apart so the UI can report honest numbers.
struct StudySessionPlan {
    let dueWords: [Corpus]
    let newWords: [Corpus]

    /// Session order: due reviews and new words interleaved by shuffling, so a
    /// session does not degenerate into "all reviews first, all new last".
    func shuffledWords() -> [Corpus] {
        (dueWords + newWords).shuffled()
    }

    static let empty = StudySessionPlan(dueWords: [], newWords: [])
}

// MARK: - Statistics

/// Counts for the four lifecycle states across the whole vocabulary.
struct LearningStateCounts {
    var new: Int = 0
    var learning: Int = 0
    var due: Int = 0
    var mastered: Int = 0

    func count(for state: WordLearningState) -> Int {
        switch state {
        case .new: return new
        case .learning: return learning
        case .due: return due
        case .mastered: return mastered
        }
    }

    static let zero = LearningStateCounts()
}

/// What happened today. `reviewSuccess`/`reviewFail` count graded answers only —
/// same-session corrections are reported separately so a day of re-quizzing
/// never looks like a day of long-term retention.
struct TodayStudySummary {
    var newIntroduced: Int = 0
    var dueReviewed: Int = 0
    var reviewSuccess: Int = 0
    var reviewFail: Int = 0
    var correctionAttempts: Int = 0
    var correctionSuccess: Int = 0

    static let zero = TodayStudySummary()
}

/// Accuracy for one question type over a time window.
struct ModeAccuracy: Identifiable {
    let mode: StudyQuestionMode
    let correct: Int
    let total: Int

    var id: String { mode.rawValue }
}

/// Recent-performance snapshot for the dashboard. Graded (long-term) accuracy
/// and same-session correction accuracy are intentionally two different fields.
struct RecentPerformance {
    var modeAccuracies: [ModeAccuracy] = []
    var correctionCorrect: Int = 0
    var correctionTotal: Int = 0

    static let empty = RecentPerformance()
}
