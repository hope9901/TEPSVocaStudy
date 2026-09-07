import Foundation
import Combine

enum SessionPhase {
    case mainQuiz       // Initial quiz session (due reviews + newly introduced words)
    case typingReview   // Reviewing incorrect words by typing them out
    case reQuiz         // Re-quiz on the previously incorrect words
    case finished       // Session completed successfully with all words memorized
}

enum TypingMode {
    case copyMode       // Copy: Shows spelling and meaning
    case blindMode      // Blind Listening: Hides spelling (blank ___), plays TTS, shows meaning & example
}

struct QuizOption: Hashable, Identifiable {
    let id = UUID()
    let word: String
    let meaning: String
}

/// One question as it is presented on screen.
struct QuizQuestion {
    let word: Corpus
    let mode: StudyQuestionMode
    /// Sentence with the target blanked out — present for context questions and
    /// used as a leak-free hint for recall questions.
    let blankedSentence: String?
}

class QuizSessionViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var phase: SessionPhase = .mainQuiz
    @Published var currentWords: [Corpus] = []
    @Published var currentIndex: Int = 0 {
        didSet {
            self.hintCount = 0
        }
    }
    @Published var incorrectWords: [Corpus] = []

    // Quiz specific properties
    @Published var currentQuestion: QuizQuestion? = nil
    @Published var options: [QuizOption] = []
    @Published var selectedAnswer: QuizOption? = nil
    @Published var isAnswered: Bool = false
    @Published var isCorrect: Bool? = nil

    // Recall (typed answer) question state
    @Published var recallInput: String = ""
    @Published var recallSubmittedAnswer: String = ""

    // Typing practice specific properties
    // (the input text itself lives as local @State in TypingInputField so
    // keystrokes don't republish the whole view model)
    @Published var isTypingSuccess: Bool = false
    @Published var typingMode: TypingMode = .copyMode
    @Published var hintCount: Int = 0

    // Session state
    @Published var isHardWordsSession: Bool = false
    @Published var totalSessionWordsCount: Int = 0
    /// How the session was composed — shown in the header and the summary so
    /// the learner sees real numbers instead of a hard-coded "100 words".
    @Published var dueWordsCount: Int = 0
    @Published var newWordsCount: Int = 0

    // Session result counters (first-attempt performance, not correction rounds)
    @Published var firstTryCorrectCount: Int = 0
    @Published var firstTryIncorrectCount: Int = 0
    @Published var correctionRounds: Int = 0

    // MARK: - Properties
    private var allWords: [Corpus] = []
    private var studyMode: StudyMode = .mixed
    /// Words already penalised in this session; a second miss inside the same
    /// sitting must not push the familiarity down again.
    private var failedWordIds: Set<String> = []
    /// The question type each word was asked with, so the re-quiz can target
    /// the same skill that failed.
    private var questionModeByWordId: [String: StudyQuestionMode] = [:]

    // Current word being tested
    var currentWord: Corpus? {
        guard currentIndex >= 0 && currentIndex < currentWords.count else { return nil }
        return currentWords[currentIndex]
    }

    // Current word for typing practice
    var currentTypingWord: Corpus? {
        guard phase == .typingReview else { return nil }
        guard currentIndex >= 0 && currentIndex < incorrectWords.count else { return nil }
        return incorrectWords[currentIndex]
    }

    /// Example sentence for the typing screen with the answer masked in blind
    /// mode. Inflected forms are masked too ("commuting" for "commute"), which a
    /// plain string replacement used to miss and leak the spelling.
    var typingExampleSentence: String? {
        guard let target = currentTypingWord,
              let example = target.exampleSentence,
              !example.isEmpty else { return nil }
        if typingMode == .copyMode {
            return example
        }
        return ContextSentenceBuilder.maskedSentence(sentence: example, target: target.word)
    }

    // Spaced out hint string based on hintCount
    var typingHintString: String {
        guard let word = currentTypingWord?.word else { return "" }
        if hintCount == 0 {
            return String(repeating: "_ ", count: word.count).trimmingCharacters(in: .whitespaces)
        } else if hintCount == 1 {
            let firstChar = String(word.prefix(1))
            let underscores = String(repeating: "_ ", count: max(0, word.count - 1)).trimmingCharacters(in: .whitespaces)
            return "\(firstChar) \(underscores)"
        } else if hintCount == 2 {
            let firstTwo = word.prefix(2)
            var result = ""
            for char in firstTwo {
                result += "\(char) "
            }
            let underscores = String(repeating: "_ ", count: max(0, word.count - 2)).trimmingCharacters(in: .whitespaces)
            return "\(result)\(underscores)"
        } else {
            return word.map { String($0) }.joined(separator: " ")
        }
    }

    // MARK: - Session Controls

    /// Starts a new study session.
    ///
    /// - Parameters:
    ///   - isHardWords: focused drill on 난공불락 words (familiar <= -3). Those
    ///     are deliberately allowed even when not due — it is an explicit,
    ///     user-requested drill — but answering them early never pushes their
    ///     review date further out (see `SRSScheduler.grade`).
    ///   - studyMode: which question types the session may ask.
    ///   - newWordsPerSession: how many brand-new words to introduce.
    ///
    /// A normal session is `due + new` only. It is never padded with words
    /// whose review date is still in the future, so a session can be short.
    func startSession(isHardWords: Bool = false, studyMode: StudyMode = .mixed, newWordsPerSession: Int = SRSConfiguration.default.newWordsPerSession) {
        self.isHardWordsSession = isHardWords
        self.studyMode = studyMode
        self.failedWordIds = []
        self.questionModeByWordId = [:]
        self.firstTryCorrectCount = 0
        self.firstTryIncorrectCount = 0
        self.correctionRounds = 0

        if isHardWords {
            let hardWords = DatabaseManager.shared.fetchHardWords()
            self.allWords = hardWords
            self.dueWordsCount = hardWords.count
            self.newWordsCount = 0
        } else {
            let plan = DatabaseManager.shared.fetchSessionPlan(config: .withNewWordLimit(newWordsPerSession))
            self.allWords = plan.shuffledWords()
            self.dueWordsCount = plan.dueWords.count
            self.newWordsCount = plan.newWords.count
        }

        self.totalSessionWordsCount = allWords.count
        self.currentWords = allWords
        self.incorrectWords = []
        self.currentIndex = 0
        self.phase = .mainQuiz

        if allWords.isEmpty {
            self.phase = .finished
        } else {
            loadCurrentQuestion()
        }
    }

    /// Prepares the current question (4 multiple choice options, or a typed
    /// recall prompt for words that are already well known).
    func loadCurrentQuestion() {
        // Reset answer states
        self.selectedAnswer = nil
        self.isAnswered = false
        self.isCorrect = nil
        self.recallInput = ""
        self.recallSubmittedAnswer = ""

        // 1. Check if the current phase's questions are all completed
        if currentIndex >= currentWords.count {
            handlePhaseTransition()
            return
        }

        // 2. Decide what to ask about this word
        guard let correct = currentWord else { return }

        let blanked = ContextSentenceBuilder.blankedSentence(sentence: correct.exampleSentence, target: correct.word)
        let mode = resolveQuestionMode(for: correct, hasContextSentence: blanked != nil)
        questionModeByWordId[correct.id] = mode

        self.currentQuestion = QuizQuestion(
            word: correct,
            mode: mode,
            blankedSentence: blanked
        )

        // 3. Build the options (recall questions are answered by typing)
        guard mode != .recall else {
            self.options = []
            return
        }

        let distractors: [Distractor]
        if mode == .context {
            distractors = DistractorService.shared.contextDistractors(for: correct, sentence: blanked, limit: 3)
        } else {
            distractors = DistractorService.shared.meaningDistractors(for: correct, limit: 3)
        }

        var allOptions: [QuizOption] = [QuizOption(word: correct.word, meaning: correct.meaning)]
        for distractor in distractors {
            allOptions.append(QuizOption(word: distractor.word, meaning: distractor.meaning))
        }
        allOptions.shuffle()
        self.options = allOptions
    }

    /// Question type for a word, honouring the session's study mode.
    /// During the re-quiz a recall miss is re-asked as a recognition question:
    /// the learner has just typed the spelling in the typing phase, so asking
    /// for it again would test nothing.
    private func resolveQuestionMode(for word: Corpus, hasContextSentence: Bool) -> StudyQuestionMode {
        if phase == .reQuiz, let originalMode = questionModeByWordId[word.id] {
            if originalMode == .recall {
                return hasContextSentence ? .context : .meaning
            }
            return originalMode
        }
        return SRSScheduler.questionMode(
            studyMode: studyMode,
            familiar: word.familiar,
            hasContextSentence: hasContextSentence
        )
    }

    /// Submits the chosen answer in Quiz mode
    func submitAnswer(option: QuizOption) {
        guard !isAnswered, let correct = currentWord else { return }

        self.selectedAnswer = option
        register(answer: correct.word == option.word, for: correct)
    }

    /// Submits a typed answer for a recall question.
    func submitRecallAnswer() {
        guard !isAnswered, let correct = currentWord else { return }
        let typed = recallInput.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recallSubmittedAnswer = typed
        let matches = typed.lowercased() == correct.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        register(answer: matches, for: correct)
    }

    /// Gives up on a recall question — counts as a miss, like any other.
    func revealRecallAnswer() {
        guard !isAnswered, let correct = currentWord else { return }
        self.recallSubmittedAnswer = recallInput.trimmingCharacters(in: .whitespacesAndNewlines)
        register(answer: false, for: correct)
    }

    /// Shared grading path for every question type.
    ///
    /// The re-quiz phase records its answers as **session corrections**: they
    /// prove today's correction worked, not that the word survived to the next
    /// day, so they never raise `familiar` and never lengthen the interval.
    private func register(answer isAnswerCorrect: Bool, for word: Corpus) {
        self.isAnswered = true
        self.isCorrect = isAnswerCorrect

        let mode = currentQuestion?.mode ?? .meaning
        let isCorrectionRound = (phase == .reQuiz)

        DatabaseManager.shared.recordAnswer(
            corpusId: word.id,
            mode: mode,
            isCorrect: isAnswerCorrect,
            isCorrection: isCorrectionRound,
            alreadyFailedThisSession: failedWordIds.contains(word.id)
        )

        if isAnswerCorrect {
            if isCorrectionRound {
                correctionRounds += 1
            } else {
                firstTryCorrectCount += 1
            }
        } else {
            if !isCorrectionRound {
                firstTryIncorrectCount += 1
            }
            failedWordIds.insert(word.id)
            incorrectWords.append(word)
        }

        // Correct pronunciation is played either way: as reward or as
        // corrective feedback.
        AudioSynthesizer.shared.speak(text: word.word)
    }

    /// Progresses to the next question in Quiz mode
    func nextQuestion() {
        self.currentIndex += 1
        loadCurrentQuestion()
    }

    // MARK: - Typing Practice Logic

    /// Triggers progressive typing hints
    func triggerHint() {
        if hintCount < 3 {
            hintCount += 1
        }
    }

    /// Handles user text input for copying/typing vocabulary spelling.
    /// Check is case-insensitive and trims whitespaces.
    func submitTypingInput(_ input: String) {
        guard let target = currentTypingWord, !isTypingSuccess else { return }

        let targetClean = target.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inputClean = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if inputClean == targetClean {
            // Play TTS on successful copy
            AudioSynthesizer.shared.speak(text: target.word)

            // Blind typing is a genuine recall attempt, so it is logged — but
            // always as a same-session correction, and only counted as a hit
            // when no hint was needed. Copy mode is transcription, not recall,
            // so it is not logged at all.
            if typingMode == .blindMode {
                DatabaseManager.shared.recordAnswer(
                    corpusId: target.id,
                    mode: .recall,
                    isCorrect: hintCount == 0,
                    isCorrection: true,
                    alreadyFailedThisSession: failedWordIds.contains(target.id)
                )
            }

            isTypingSuccess = true

            // Advance to the next word with a slight delay for smooth UI feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.isTypingSuccess = false
                self.currentIndex += 1

                // Check if all typing reviews are completed
                if self.currentIndex >= self.incorrectWords.count {
                    self.handlePhaseTransition()
                } else {
                    // If in blind mode, auto play TTS for the next word
                    if self.typingMode == .blindMode, let nextWord = self.currentTypingWord {
                        AudioSynthesizer.shared.speak(text: nextWord.word)
                    }
                }
            }
        }
    }

    // MARK: - Phase State Transitions

    private func handlePhaseTransition() {
        if phase == .mainQuiz || phase == .reQuiz {
            // If quiz phase is done:
            if incorrectWords.isEmpty {
                // If there are no incorrect words, session is successfully completed!
                self.phase = .finished
            } else {
                // Move to typing review phase for incorrect words
                self.phase = .typingReview
                self.currentIndex = 0
                // Auto speak first typing word to help memory
                if let firstTyping = currentTypingWord {
                    AudioSynthesizer.shared.speak(text: firstTyping.word)
                }
            }
        } else if phase == .typingReview {
            // Typing practice completed:
            // Move to reQuiz phase, testing only the previously incorrect words
            self.phase = .reQuiz
            self.currentWords = incorrectWords
            self.incorrectWords = [] // Clear buffer for new quiz session
            self.currentIndex = 0
            loadCurrentQuestion()
        }
    }
}
