import Foundation
import Combine

enum SessionPhase {
    case mainQuiz       // Today's due reviews + new words (or the hard-word drill)
    case typingReview   // Reviewing incorrect words by typing them out
    case reQuiz         // Re-quiz on the previously incorrect words
    case finished       // Session completed (or nothing to study today)
}

enum TypingMode {
    case copyMode       // Copy: Shows spelling and meaning
    case blindMode      // Blind Listening: Hides spelling (blank ___), plays TTS, shows meaning & example
}

struct QuizOption: Hashable, Identifiable {
    let id = UUID()
    let corpusId: String
    let word: String
    let meaning: String
}

/// What the session achieved, split by kind of evidence.
struct SessionSummary: Equatable {
    var newStudied = 0
    var newCorrect = 0
    var reviewed = 0
    var reviewCorrect = 0
    var drilled = 0
    var drillCorrect = 0
    /// Words missed on the first attempt and then fixed via typing + re-quiz.
    var corrected = 0

    var firstAttemptTotal: Int { newStudied + reviewed + drilled }
    var firstAttemptCorrect: Int { newCorrect + reviewCorrect + drillCorrect }
}

class QuizSessionViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var phase: SessionPhase = .mainQuiz
    @Published var currentItems: [SessionItem] = []
    @Published var currentIndex: Int = 0 {
        didSet {
            self.hintCount = 0
        }
    }
    @Published var incorrectItems: [SessionItem] = []

    // Quiz specific properties
    @Published var options: [QuizOption] = []
    @Published var selectedAnswer: QuizOption? = nil
    @Published var isAnswered: Bool = false
    @Published var isCorrect: Bool? = nil

    // Typing practice specific properties
    // (the input text itself lives as local @State in TypingInputField so
    // keystrokes don't republish the whole view model)
    @Published var isTypingSuccess: Bool = false
    @Published var typingMode: TypingMode = .copyMode
    @Published var hintCount: Int = 0

    // Session state
    @Published private(set) var mode: StudyMode = .meaning
    @Published var totalSessionWordsCount: Int = 0
    @Published private(set) var plannedDueCount: Int = 0
    @Published private(set) var plannedNewCount: Int = 0
    @Published private(set) var summary = SessionSummary()

    var isHardWordsSession: Bool { mode == .hardWords }

    // MARK: - Properties
    private let database: DatabaseManager
    private var distractors: DistractorService?
    private var translations: [String: String]?
    /// Words already answered once this session; later answers are corrections.
    private var firstAttempted: Set<String> = []
    private var correctedIds: Set<String> = []

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // Current question
    var currentItem: SessionItem? {
        guard currentIndex >= 0 && currentIndex < currentItems.count else { return nil }
        return currentItems[currentIndex]
    }

    var currentWord: Corpus? { currentItem?.corpus }

    /// Korean translation of a word's example sentence. Views show it only after
    /// the answer is revealed — it restates the meaning.
    func exampleTranslation(for corpus: Corpus) -> String? {
        if translations == nil {
            translations = database.fetchExampleTranslations()
        }
        return translations?[corpus.id]
    }

    // Current word for typing practice
    var currentTypingItem: SessionItem? {
        guard phase == .typingReview else { return nil }
        guard currentIndex >= 0 && currentIndex < incorrectItems.count else { return nil }
        return incorrectItems[currentIndex]
    }

    var currentTypingWord: Corpus? { currentTypingItem?.corpus }

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
    /// - Parameters:
    ///   - mode: `.meaning` / `.context` build today's due + new session; `.hardWords` drills familiar <= -3.
    ///   - extraNewWords: study this many extra NEW words beyond today's quota.
    func startSession(mode: StudyMode, extraNewWords: Int = 0, now: Date = Date()) {
        self.mode = mode
        let plan = SessionPlanner(database: database).plan(
            mode: mode,
            dailyNewLimit: SessionPlanner.dailyNewLimit(),
            extraNewWords: extraNewWords,
            now: now
        )

        self.plannedDueCount = plan.dueCount
        self.plannedNewCount = plan.newCount
        self.totalSessionWordsCount = plan.items.count
        self.currentItems = plan.items
        self.incorrectItems = []
        self.firstAttempted = []
        self.correctedIds = []
        self.summary = SessionSummary()
        self.currentIndex = 0
        self.phase = .mainQuiz

        if plan.items.isEmpty {
            self.phase = .finished
        } else {
            if distractors == nil {
                distractors = DistractorService(pool: database.fetchAllActiveWords())
            }
            loadCurrentQuestion()
        }
    }

    /// Prepares the current question (4 multiple choice options)
    func loadCurrentQuestion() {
        // Reset answer states
        self.selectedAnswer = nil
        self.isAnswered = false
        self.isCorrect = nil

        // 1. Check if the current phase's questions are all completed
        if currentIndex >= currentItems.count {
            handlePhaseTransition()
            return
        }

        // 2. Setup multiple choice options
        guard let item = currentItem, let service = distractors else { return }
        let correct = item.corpus

        let wrong: [Corpus]
        if item.quizType == .context, let sentence = item.blankedSentence {
            wrong = service.contextDistractors(for: correct, blankedSentence: sentence, count: 3)
        } else {
            wrong = service.meaningDistractors(for: correct, count: 3)
        }

        var allOptions = [QuizOption(corpusId: correct.id, word: correct.word, meaning: correct.meaning)]
        allOptions += wrong.map { QuizOption(corpusId: $0.id, word: $0.word, meaning: $0.meaning) }
        self.options = allOptions.shuffled()
    }

    /// Submits the chosen answer in Quiz mode
    func submitAnswer(option: QuizOption, now: Date = Date()) {
        guard !isAnswered, let item = currentItem else { return }

        self.selectedAnswer = option
        self.isAnswered = true

        let correctFlag = option.corpusId == item.corpus.id
        self.isCorrect = correctFlag

        if phase == .mainQuiz && !firstAttempted.contains(item.corpus.id) {
            // First answer this session = long-term evidence (or a drill on a not-yet-due word).
            firstAttempted.insert(item.corpus.id)
            let context = database.recordFirstAnswer(corpusId: item.corpus.id, quizType: item.quizType, correct: correctFlag, now: now)
            tally(context: context, correct: correctFlag)
        } else {
            // Re-quiz after typing: "corrected today", never a long-term success.
            database.recordCorrection(corpusId: item.corpus.id, quizType: item.quizType, correct: correctFlag, now: now)
        }

        if !correctFlag {
            incorrectItems.append(item)
            correctedIds.insert(item.corpus.id)
            summary.corrected = correctedIds.count
        }
        // Pronounce the correct word as feedback either way
        AudioSynthesizer.shared.speak(text: item.corpus.word)
    }

    /// Progresses to the next question in Quiz mode
    func nextQuestion() {
        self.currentIndex += 1
        loadCurrentQuestion()
    }

    private func tally(context: ReviewContext, correct: Bool) {
        switch context {
        case .newWord:
            summary.newStudied += 1
            if correct { summary.newCorrect += 1 }
        case .review:
            summary.reviewed += 1
            if correct { summary.reviewCorrect += 1 }
        case .drill, .correction:
            summary.drilled += 1
            if correct { summary.drillCorrect += 1 }
        }
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
            // Blind listening is a recall attempt; finishing without hints counts as
            // a recall success. Copy mode only reproduces visible text — not logged.
            if typingMode == .blindMode {
                database.recordCorrection(corpusId: target.id, quizType: .recall, correct: hintCount == 0)
            }

            // Play TTS on successful copy
            AudioSynthesizer.shared.speak(text: target.word)

            isTypingSuccess = true

            // Advance to the next word with a slight delay for smooth UI feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.isTypingSuccess = false
                self.currentIndex += 1

                // Check if all typing reviews are completed
                if self.currentIndex >= self.incorrectItems.count {
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
            if incorrectItems.isEmpty {
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
            self.currentItems = incorrectItems
            self.incorrectItems = [] // Clear buffer for new quiz session
            self.currentIndex = 0
            loadCurrentQuestion()
        }
    }
}
