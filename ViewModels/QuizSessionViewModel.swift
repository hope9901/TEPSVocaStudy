import Foundation
import Combine

enum SessionPhase {
    case mainQuiz       // Initial quiz session (100 words or hard words)
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

class QuizSessionViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var phase: SessionPhase = .mainQuiz
    @Published var currentWords: [Corpus] = []
    @Published var currentIndex: Int = 0
    @Published var incorrectWords: [Corpus] = []
    
    // Quiz specific properties
    @Published var options: [QuizOption] = []
    @Published var selectedAnswer: QuizOption? = nil
    @Published var isAnswered: Bool = false
    @Published var isCorrect: Bool? = nil
    
    // Typing practice specific properties
    @Published var typingInput: String = ""
    @Published var isTypingSuccess: Bool = false
    @Published var typingMode: TypingMode = .copyMode
    
    // Session state
    @Published var isHardWordsSession: Bool = false
    @Published var totalSessionWordsCount: Int = 0
    
    // MARK: - Properties
    private var allWords: [Corpus] = []
    
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
    
    // MARK: - Session Controls
    
    /// Starts a new study session.
    /// - Parameter isHardWords: If true, loads only words with familiarity <= -3. Otherwise loads 100 random unmemorized words.
    func startSession(isHardWords: Bool = false) {
        self.isHardWordsSession = isHardWords
        
        if isHardWords {
            self.allWords = DatabaseManager.shared.fetchHardWords()
        } else {
            self.allWords = DatabaseManager.shared.fetchStudyWords(limit: 100)
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
    
    /// Prepares the current question (4 multiple choice options)
    func loadCurrentQuestion() {
        // Reset answer states
        self.selectedAnswer = nil
        self.isAnswered = false
        self.isCorrect = nil
        
        // 1. Check if the current phase's questions are all completed
        if currentIndex >= currentWords.count {
            handlePhaseTransition()
            return
        }
        
        // 2. Setup multiple choice options
        guard let correct = currentWord else { return }
        
        // Get 3 incorrect meanings (now returns [Distractor])
        let distractors = DatabaseManager.shared.fetchDistractorMeanings(correctWord: correct.word, correctId: correct.id, limit: 3)
        
        var allOptions: [QuizOption] = []
        
        // Add correct option
        allOptions.append(QuizOption(word: correct.word, meaning: correct.meaning))
        
        // Add distractors
        for d in distractors {
            allOptions.append(QuizOption(word: d.word, meaning: d.meaning))
        }
        
        allOptions.shuffle()
        self.options = allOptions
    }
    
    /// Submits the chosen answer in Quiz mode
    func submitAnswer(option: QuizOption) {
        guard !isAnswered, let correct = currentWord else { return }
        
        self.selectedAnswer = option
        self.isAnswered = true
        
        let correctFlag = (correct.word == option.word)
        self.isCorrect = correctFlag
        
        if correctFlag {
            // Correct answer: increment familiarity, auto-play TTS
            DatabaseManager.shared.updateFamiliarity(id: correct.id, increment: 1)
            AudioSynthesizer.shared.speak(text: correct.word)
        } else {
            // Incorrect answer: decrement familiarity, add to incorrect list
            DatabaseManager.shared.updateFamiliarity(id: correct.id, increment: -1)
            incorrectWords.append(correct)
            
            // Speak correct pronunciation as corrective feedback
            AudioSynthesizer.shared.speak(text: correct.word)
        }
    }
    
    /// Progresses to the next question in Quiz mode
    func nextQuestion() {
        self.currentIndex += 1
        loadCurrentQuestion()
    }
    
    // MARK: - Typing Practice Logic
    
    /// Handles user text input for copying/typing vocabulary spelling.
    /// Check is case-insensitive and trims whitespaces.
    func handleTypingInputChanged() {
        guard let target = currentTypingWord else { return }
        
        let targetClean = target.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inputClean = typingInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if inputClean == targetClean {
            // Play TTS on successful copy
            AudioSynthesizer.shared.speak(text: target.word)
            
            isTypingSuccess = true
            
            // Advance to the next word with a slight delay for smooth UI feedback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.typingInput = ""
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
