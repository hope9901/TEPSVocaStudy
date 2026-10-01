import Foundation

/// Builds a study session from words that actually need work today:
/// due reviews first, then up to the remaining daily quota of NEW words.
/// It never pads the session — words scheduled for a later day are not fillers,
/// so a short session is the correct result when little is due.
struct SessionPlanner {
    static let maxSessionSize = 100
    static let dailyNewLimitKey = "dailyNewWordLimit"
    static let defaultDailyNewLimit = 20

    let database: DatabaseManager

    static func dailyNewLimit(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: dailyNewLimitKey)
        return stored > 0 ? stored : defaultDailyNewLimit
    }

    /// - Parameter extraNewWords: when > 0, study this many NEW words beyond the
    ///   daily quota (the user explicitly asked for more).
    func plan(mode: StudyMode, dailyNewLimit: Int, extraNewWords: Int = 0, now: Date = Date()) -> SessionPlan {
        if mode == .hardWords {
            let items = database.fetchHardWords().map { corpus in
                SessionItem(corpus: corpus, quizType: .meaning,
                            origin: database.reviewContext(forCorpusId: corpus.id, now: now),
                            blankedSentence: nil)
            }
            return SessionPlan(items: items, dueCount: items.filter { $0.origin == .review }.count, newCount: 0)
        }

        let due = database.fetchDueWords(now: now, limit: Self.maxSessionSize)
        let newSlots: Int
        if extraNewWords > 0 {
            newSlots = extraNewWords
        } else {
            let studiedToday = database.countNewWordsStudied(since: StudyClock.startOfDay(now))
            newSlots = max(0, dailyNewLimit - studiedToday)
        }
        let fresh = database.fetchNewWords(limit: min(newSlots, Self.maxSessionSize - due.count))

        let preferredType: QuizType = mode == .context ? .context : .meaning
        let items = (due.map { ($0, ReviewContext.review) } + fresh.map { ($0, ReviewContext.newWord) })
            .map { corpus, origin in makeItem(corpus, origin: origin, preferred: preferredType) }
            .shuffled()
        return SessionPlan(items: items, dueCount: due.count, newCount: fresh.count)
    }

    /// A context question needs the word to really appear in its example;
    /// otherwise the word is still reviewed, as a meaning question.
    func makeItem(_ corpus: Corpus, origin: ReviewContext, preferred: QuizType) -> SessionItem {
        if preferred == .context,
           let sentence = corpus.exampleSentence, !sentence.isEmpty,
           let blanked = ContextBlanker.blanked(corpus.word, in: sentence) {
            return SessionItem(corpus: corpus, quizType: .context, origin: origin, blankedSentence: blanked)
        }
        return SessionItem(corpus: corpus, quizType: .meaning, origin: origin, blankedSentence: nil)
    }
}
