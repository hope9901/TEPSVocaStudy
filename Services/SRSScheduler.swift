import Foundation

/// Result of grading a single answer.
/// `scheduledAt == nil` means "leave the existing review date alone" — used for
/// focused drills (난공불락 집중 학습) on words that were not actually due, so
/// practising them never inflates their interval.
struct ReviewGrade {
    let familiar: Int
    let scheduledAt: Date?
    let intervalDays: Int
    /// True when this answer counts towards long-term retention statistics.
    /// Same-session corrections (타이핑 → 재퀴즈) are false.
    let countsAsGradedReview: Bool
    let isLapse: Bool
}

/// Spaced-repetition rules, kept as pure functions so they can be reasoned
/// about (and ported to a test harness) without a database or a UI.
///
/// Two invariants drive the whole design:
///
/// 1. A word whose `scheduledAt` is in the future is *never* eligible for a
///    normal study session — not as a filler, not as a fallback. Sessions are
///    `due + new` and are allowed to be small.
/// 2. Getting a word right again inside the same session is **correction**, not
///    retention. Corrections never raise `familiar` and never lengthen an
///    interval; only a graded review on a later day can do that.
enum SRSScheduler {

    // MARK: - Tuning

    /// `familiar` stays in the legacy [-5, 5] range so existing data, the
    /// "외운 단어" (>= 3) counter and 난공불락 words (<= -3) keep working.
    static let minFamiliar = -5
    static let maxFamiliar = 5

    /// Familiarity at which a word is considered parked in long-term memory.
    static let masteredFamiliarThreshold = 4

    /// Ebbinghaus-style ladder, indexed by the familiarity *after* a correct
    /// answer. Unchanged from the original app so existing schedules stay
    /// meaningful.
    static func intervalDays(forFamiliar familiar: Int) -> Int {
        switch familiar {
        case ...1: return 1
        case 2: return 3
        case 3: return 7
        case 4: return 14
        default: return 30
        }
    }

    /// Interval used after a miss: the word comes back on the next study day,
    /// not later the same day.
    static let lapseIntervalDays = 1

    // MARK: - Date helpers

    /// Review dates land on the start of a future *local* day, which makes
    /// "due today" a stable concept regardless of what time of day the user
    /// studies. `days` is always >= 1, so a word graded now can never become
    /// due again during the same calendar day.
    static func reviewDate(daysFromNow days: Int, now: Date, calendar: Calendar = .current) -> Date {
        let safeDays = max(1, days)
        let startOfToday = calendar.startOfDay(for: now)
        let target = calendar.date(byAdding: .day, value: safeDays, to: startOfToday) ?? now.addingTimeInterval(Double(safeDays) * 86_400)
        // Guard against DST/calendar oddities producing a date in the past.
        return target > now ? target : now.addingTimeInterval(Double(safeDays) * 86_400)
    }

    // MARK: - Grading

    /// Grades one answer.
    ///
    /// - Parameters:
    ///   - familiar: current `Corpus.familiar`
    ///   - isDue: whether `Corpus.scheduledAt` has already arrived. The caller
    ///     resolves this in SQL, so the legacy date formats stored in the
    ///     corpus never have to be parsed in Swift.
    ///   - isCorrect: whether the answer was right
    ///   - isCorrection: true when the answer happened in the same session as
    ///     the mistake it is fixing (오답 타이핑 후 재퀴즈)
    ///   - alreadyFailedThisSession: true when this word has already been
    ///     penalised in this session, so a repeated miss does not spiral the
    ///     familiarity down to -5 in a single sitting
    static func grade(
        familiar: Int,
        isDue: Bool,
        isCorrect: Bool,
        isCorrection: Bool,
        alreadyFailedThisSession: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReviewGrade {
        let clampedFamiliar = clamp(familiar)

        // --- Same-session correction -------------------------------------
        // The word was just missed; re-answering it now proves today's
        // correction worked, not that it survived a night of forgetting.
        // Familiarity is untouched and the word stays scheduled for tomorrow.
        if isCorrection {
            return ReviewGrade(
                familiar: clampedFamiliar,
                scheduledAt: reviewDate(daysFromNow: lapseIntervalDays, now: now, calendar: calendar),
                intervalDays: lapseIntervalDays,
                countsAsGradedReview: false,
                isLapse: false
            )
        }

        // --- Graded miss ---------------------------------------------------
        if !isCorrect {
            let newFamiliar = alreadyFailedThisSession ? clampedFamiliar : clamp(clampedFamiliar - 1)
            // Always tomorrow: never "now" (which would let the word come back
            // in another session today) and never later than tomorrow either,
            // because a missed word has to be re-tested soon.
            return ReviewGrade(
                familiar: newFamiliar,
                scheduledAt: reviewDate(daysFromNow: lapseIntervalDays, now: now, calendar: calendar),
                intervalDays: lapseIntervalDays,
                countsAsGradedReview: true,
                isLapse: true
            )
        }

        // --- Graded hit ----------------------------------------------------
        let newFamiliar = clamp(clampedFamiliar + 1)
        guard isDue else {
            // Practised ahead of schedule (e.g. 난공불락 집중 학습). Credit the
            // familiarity but keep the existing review date: answering a word
            // early must not push its next review further away.
            return ReviewGrade(
                familiar: newFamiliar,
                scheduledAt: nil,
                intervalDays: 0,
                countsAsGradedReview: true,
                isLapse: false
            )
        }

        let interval = intervalDays(forFamiliar: newFamiliar)
        return ReviewGrade(
            familiar: newFamiliar,
            scheduledAt: reviewDate(daysFromNow: interval, now: now, calendar: calendar),
            intervalDays: interval,
            countsAsGradedReview: true,
            isLapse: false
        )
    }

    // MARK: - Question selection

    /// Picks the question type for a word inside a session.
    ///
    /// Weak words are asked for meaning first — pushing an unknown word
    /// straight into a cloze sentence is guesswork. Once the meaning is known
    /// the word moves to context questions (what TEPS actually tests), and
    /// mature words are asked for production (typing the spelling).
    static func questionMode(
        studyMode: StudyMode,
        familiar: Int,
        hasContextSentence: Bool
    ) -> StudyQuestionMode {
        switch studyMode {
        case .meaningOnly:
            return .meaning
        case .contextOnly:
            return hasContextSentence ? .context : .meaning
        case .mixed:
            if familiar >= masteredFamiliarThreshold - 1 {
                // Well-known word: ask it to be produced, not recognised.
                return .recall
            }
            if familiar >= 1 && hasContextSentence {
                return .context
            }
            return .meaning
        }
    }

    // MARK: - Helpers

    static func clamp(_ familiar: Int) -> Int {
        min(maxFamiliar, max(minFamiliar, familiar))
    }
}
