import Foundation

/// Pure spaced-repetition rules. No database access, so every rule is unit-testable.
///
/// Scheduling is driven only by long-term evidence: the first answer to a NEW
/// word, or the first answer to a word whose review date has arrived.
/// Same-session correction (typing, re-quiz) never reaches this type.
enum SRSScheduler {
    /// Interval in days after the n-th consecutive successful spaced review.
    /// Index 0 is used for a first exposure and for a lapse.
    static let intervalLadder = [1, 3, 7, 14, 30, 60, 120]

    /// MASTERED needs a long interval *and* proof the word works in context,
    /// so recognising a translation alone is never enough.
    static let masteryMinInterval = 14

    struct Outcome: Equatable {
        let progress: WordProgress
        let familiar: Int
    }

    /// Applies one long-term answer.
    /// - Parameters:
    ///   - existing: nil for a NEW word.
    ///   - familiar: the word's current Corpus.familiar (kept for the hard-word feature).
    static func apply(
        existing: WordProgress?,
        corpusId: String,
        familiar: Int,
        quizType: QuizType,
        correct: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> Outcome {
        let nowISO = StudyClock.iso(now)
        var progress = existing ?? WordProgress(
            corpusId: corpusId,
            state: .learning,
            intervalDays: 0,
            reviewStreak: 0,
            lapses: 0,
            firstStudiedAt: nowISO,
            lastReviewedAt: nil,
            nextReviewAt: nowISO
        )
        let isFirstExposure = existing == nil

        recordCounters(&progress, quizType: quizType, correct: correct)

        if correct {
            if isFirstExposure {
                // Recognising a word the first time may be a lucky guess (1 in 4),
                // so it only earns a next-day check, not a spaced interval.
                progress.state = .learning
                progress.intervalDays = intervalLadder[0]
            } else {
                progress.reviewStreak += 1
                let step = min(progress.reviewStreak, intervalLadder.count - 1)
                progress.intervalDays = intervalLadder[step]
                progress.state = .review
            }
        } else {
            if !isFirstExposure {
                progress.lapses += 1
            }
            progress.reviewStreak = 0
            progress.state = .learning
            // The session itself already re-drills a miss (typing → re-quiz),
            // so the next long-term check is tomorrow, not later today.
            progress.intervalDays = intervalLadder[0]
        }

        if progress.state == .review && isMastered(progress) {
            progress.state = .mastered
        }

        progress.lastReviewedAt = nowISO
        progress.nextReviewAt = StudyClock.iso(nextReviewDate(afterDays: progress.intervalDays, from: now, calendar: calendar))

        let newFamiliar = max(-5, min(5, familiar + (correct ? 1 : -1)))
        return Outcome(progress: progress, familiar: newFamiliar)
    }

    static func isMastered(_ progress: WordProgress) -> Bool {
        progress.intervalDays >= masteryMinInterval && progress.contextCorrect > 0
    }

    /// Day-based due date: local midnight `days` days after today.
    static func nextReviewDate(afterDays days: Int, from now: Date, calendar: Calendar = .current) -> Date {
        let today = StudyClock.startOfDay(now, calendar: calendar)
        return calendar.date(byAdding: .day, value: max(1, days), to: today) ?? now.addingTimeInterval(Double(max(1, days)) * 86_400)
    }

    private static func recordCounters(_ progress: inout WordProgress, quizType: QuizType, correct: Bool) {
        switch (quizType, correct) {
        case (.meaning, true): progress.meaningCorrect += 1
        case (.meaning, false): progress.meaningWrong += 1
        case (.context, true): progress.contextCorrect += 1
        case (.context, false): progress.contextWrong += 1
        case (.recall, true): progress.recallCorrect += 1
        case (.recall, false): progress.recallWrong += 1
        }
    }
}
