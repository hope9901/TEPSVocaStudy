import Foundation

// MARK: - Quiz & review classification

/// The kind of retrieval a question asks for. Stored in ReviewLog.quizType.
enum QuizType: Int, CaseIterable {
    case meaning = 0   // English word → choose the Korean meaning (recognition)
    case context = 1   // Sentence with a blank → choose the English word (TEPS-style recognition)
    case recall = 2    // Meaning/sound/context → type the English word (production)
}

/// Why a word was answered. Stored in ReviewLog.context.
/// Only `.newWord` and `.review` answers are long-term SRS evidence; the rest
/// must never be mixed into SRS accuracy.
enum ReviewContext: Int {
    case newWord = 0     // first time this word is studied in the app
    case review = 1      // scheduled spaced review (nextReviewAt reached)
    case correction = 2  // same-session correction: typing review / re-quiz
    case drill = 3       // hard-word drill on a word that is not due yet
}

/// Lifecycle state of a word. NEW words have no WordProgress row.
enum SRSState: Int {
    case new = 0
    case learning = 1    // not yet recalled successfully on a later day, or lapsed
    case review = 2      // passed at least one spaced review
    case mastered = 3    // long interval reached and confirmed in context
}

/// How a session is composed and which question format it uses.
enum StudyMode: Equatable {
    case meaning        // daily SRS session, meaning-recognition questions
    case context        // daily SRS session, TEPS context (fill-in-the-blank) questions
    case hardWords      // drill all words with familiar <= -3, regardless of schedule
}

// MARK: - Persistence models

struct WordProgress: Equatable {
    let corpusId: String
    var state: SRSState
    var intervalDays: Int
    /// Consecutive successful spaced reviews (same-day answers never count).
    var reviewStreak: Int
    var lapses: Int
    var firstStudiedAt: String?
    var lastReviewedAt: String?
    var nextReviewAt: String
    var meaningCorrect: Int = 0
    var meaningWrong: Int = 0
    var contextCorrect: Int = 0
    var contextWrong: Int = 0
    var recallCorrect: Int = 0
    var recallWrong: Int = 0
}

// MARK: - Session plan

/// One question in a session. `origin` decides how the answer is scored.
struct SessionItem: Identifiable, Equatable {
    var id: String { corpus.id }
    let corpus: Corpus
    let quizType: QuizType
    let origin: ReviewContext
    /// The example sentence with the target replaced by a blank (context questions only).
    let blankedSentence: String?
}

struct SessionPlan {
    let items: [SessionItem]
    let dueCount: Int
    let newCount: Int
}

// MARK: - Dashboard statistics

struct StateCounts: Equatable {
    var new = 0
    var learning = 0
    var due = 0
    var mastered = 0
}

struct TodayStats: Equatable {
    var newStudied = 0
    var reviewCorrect = 0
    var reviewWrong = 0
    var dueRemaining = 0
    var newRemaining = 0
}

struct Accuracy: Equatable {
    var correct = 0
    var total = 0
    var ratio: Double? { total > 0 ? Double(correct) / Double(total) : nil }
}

struct AccuracyReport: Equatable {
    /// First attempts on new/due words in the last 7 days (long-term SRS evidence).
    var meaning = Accuracy()
    var context = Accuracy()
    /// Blind-listening typing finished without hints (same-session production).
    var recall = Accuracy()
    /// Re-quiz answers right after correction — reported separately on purpose.
    var sessionRetest = Accuracy()
}

// MARK: - Shared time helpers

enum StudyClock {
    /// All timestamps written by the SRS use this exact format so that string
    /// comparison in SQL matches chronological order.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(fromISO string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Reviews are day-based: a word due "in 1 day" becomes due at the next
    /// local midnight, never later the same day.
    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}
