import Foundation
import Combine

class AddWordViewModel: ObservableObject {
    // MARK: - Input Properties
    @Published var wordInput: String = ""
    @Published var meaningInput: String = ""
    @Published var exampleInput: String = ""
    
    // MARK: - Output Properties
    @Published var searchResults: [Corpus] = []
    @Published var isDuplicate: Bool = false
    @Published var showSuccessAlert: Bool = false
    @Published var errorMessage: String? = nil
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Debounce the input by 300ms to throttle DB reads
        $wordInput
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch(text: text)
            }
            .store(in: &cancellables)
    }
    
    /// Triggered automatically via debounced publisher
    private func performSearch(text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            self.searchResults = []
            self.isDuplicate = false
            return
        }
        
        // Search prefix matching in DB
        self.searchResults = DatabaseManager.shared.searchWords(prefix: query)
        // Check exact duplicate
        self.isDuplicate = DatabaseManager.shared.checkWordExists(word: query)
    }
    
    /// Submits the new word to the Database
    func addWord() {
        let trimmedWord = wordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeaning = meaningInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExample = exampleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validation
        guard !trimmedWord.isEmpty else {
            errorMessage = "영어 단어를 입력해주세요."
            return
        }
        
        guard !trimmedMeaning.isEmpty else {
            errorMessage = "한글 뜻을 입력해주세요."
            return
        }
        
        if DatabaseManager.shared.checkWordExists(word: trimmedWord) {
            errorMessage = "이미 등록되어 있는 단어입니다."
            isDuplicate = true
            return
        }
        
        // Insert into database
        let success = DatabaseManager.shared.insertWord(
            word: trimmedWord,
            meaning: trimmedMeaning,
            example: trimmedExample
        )
        
        if success {
            self.showSuccessAlert = true
            // Reset fields
            self.wordInput = ""
            self.meaningInput = ""
            self.exampleInput = ""
            self.searchResults = []
            self.isDuplicate = false
            self.errorMessage = nil
        } else {
            errorMessage = "단어 저장에 실패했습니다. DB 에러를 확인하세요."
        }
    }
}
