import SwiftUI

struct QuizView: View {
    @ObservedObject var viewModel: QuizSessionViewModel

    private var question: QuizQuestion? { viewModel.currentQuestion }

    var body: some View {
        VStack(spacing: 24) {
            // Prompt card (scrolls when a long sentence exceeds the space left
            // over by the answer options, instead of truncating the text)
            if let question = question {
                ScrollView(showsIndicators: false) {
                    promptCard(for: question)
                        .padding(.vertical, 36)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        .padding(.top, 16)
                }
            } else {
                Spacer()
            }

            if question?.mode == .recall {
                RecallAnswerField(viewModel: viewModel)
            } else {
                // Multiple Choice Options (4-choice Distractors)
                VStack(spacing: 14) {
                    ForEach(viewModel.options) { option in
                        OptionButton(
                            option: option,
                            showsWordAsAnswer: question?.mode == .context,
                            isSelected: viewModel.selectedAnswer?.id == option.id,
                            isCorrect: viewModel.currentWord?.word == option.word,
                            isAnswered: viewModel.isAnswered,
                            action: {
                                viewModel.submitAnswer(option: option)
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }

            Spacer()

            // Next Question Button
            if viewModel.isAnswered {
                Button(action: {
                    viewModel.nextQuestion()
                }) {
                    HStack {
                        Text(viewModel.currentIndex == viewModel.currentWords.count - 1 ? "결과 보기" : "다음 단어로")
                            .fontWeight(.bold)
                        Image(systemName: "arrow.right")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "6366F1"))
                    .cornerRadius(16)
                    .shadow(color: Color(hex: "6366F1").opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // Invisible spacer placeholder to prevent layout jumping
                Color.clear
                    .frame(height: 54)
                    .padding(.horizontal)
                    .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Prompt

    @ViewBuilder
    private func promptCard(for question: QuizQuestion) -> some View {
        switch question.mode {
        case .meaning:
            meaningPrompt(for: question)
        case .context:
            contextPrompt(for: question)
        case .recall:
            recallPrompt(for: question)
        }
    }

    /// English word → Korean meaning. The example sentence is revealed **after**
    /// answering only: shown up front it often contains the answer's collocation
    /// and turns a vocabulary question into a reading-comprehension freebie.
    private func meaningPrompt(for question: QuizQuestion) -> some View {
        VStack(spacing: 20) {
            wordHeadline(question.word.word)

            if viewModel.isAnswered, let sentence = question.word.exampleSentence, !sentence.isEmpty {
                exampleBlock(title: "뉘앙스 예문", text: sentence)
            }
        }
    }

    /// TEPS-style item: a sentence with a blank, four English words to choose
    /// from. The word itself and its meaning stay hidden until an answer is in.
    private func contextPrompt(for question: QuizQuestion) -> some View {
        VStack(spacing: 18) {
            Text("빈칸에 알맞은 단어를 고르세요")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(Color(hex: "818CF8"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(hex: "818CF8").opacity(0.12))
                .cornerRadius(8)

            Text(question.blankedSentence ?? question.word.exampleSentence ?? "")
                .font(.system(size: 21, weight: .medium, design: .serif))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isAnswered {
                answerReveal(for: question)
            }
        }
    }

    /// Meaning (and a blanked sentence when there is one) → type the spelling.
    /// Reserved for words the learner already recognises reliably.
    private func recallPrompt(for question: QuizQuestion) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Text("뜻을 보고 영어 스펠링을 직접 입력하세요")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(Color(hex: "F472B6"))
                Button(action: {
                    AudioSynthesizer.shared.speak(text: question.word.word)
                }) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundColor(Color(hex: "F472B6"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(hex: "F472B6").opacity(0.12))
            .cornerRadius(8)

            Text(question.word.meaning.condensedMeaning(maxVariants: 3))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let blanked = question.blankedSentence {
                Text(blanked)
                    .font(.subheadline)
                    .italic()
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.isAnswered {
                answerReveal(for: question)
            }
        }
    }

    // MARK: - Shared pieces

    private func wordHeadline(_ word: String) -> some View {
        HStack(spacing: 12) {
            Text(word)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(2)

            Button(action: {
                AudioSynthesizer.shared.speak(text: word)
            }) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title3)
                    .foregroundColor(Color(hex: "818CF8"))
                    .padding(10)
                    .background(Color(hex: "818CF8").opacity(0.12))
                    .clipShape(Circle())
            }
        }
    }

    /// Post-answer reveal: the word, its meaning and the full sentence.
    private func answerReveal(for question: QuizQuestion) -> some View {
        VStack(spacing: 10) {
            Divider().background(Color.white.opacity(0.08))

            wordHeadline(question.word.word)

            Text(question.word.meaning.condensedMeaning(maxVariants: 3))
                .font(.headline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isCorrect == false, !viewModel.recallSubmittedAnswer.isEmpty {
                Text("입력한 답: \(viewModel.recallSubmittedAnswer)")
                    .font(.caption)
                    .foregroundColor(Color(hex: "F87171"))
            }

            if let sentence = question.word.exampleSentence, !sentence.isEmpty {
                exampleBlock(title: "완성된 예문", text: sentence)
            }
        }
        .padding(.top, 4)
    }

    private func exampleBlock(title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(Color(hex: "818CF8").opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "818CF8").opacity(0.1))
                .cornerRadius(6)

            Text(text)
                .font(.subheadline)
                .italic()
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
        }
        .padding(.top, 10)
        .transition(.opacity)
    }
}

// MARK: - Recall Input

/// Typed answer field for recall questions. Keeps the draft in local state so a
/// keystroke does not republish the whole session view model.
struct RecallAnswerField: View {
    @ObservedObject var viewModel: QuizSessionViewModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TextField("영어 스펠링 입력", text: $text)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(height: 56)
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .focused($isFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .disabled(viewModel.isAnswered)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1.5)
                )
                .onSubmit(submit)

            if !viewModel.isAnswered {
                HStack(spacing: 12) {
                    Button(action: submit) {
                        Text("확인")
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(hex: "6366F1"))
                            .cornerRadius(14)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

                    Button(action: {
                        isFocused = false
                        viewModel.recallInput = text
                        viewModel.revealRecallAnswer()
                    }) {
                        Text("모르겠어요")
                            .fontWeight(.semibold)
                            .foregroundColor(.white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(14)
                    }
                }
            }
        }
        .padding(.horizontal)
        .onChange(of: viewModel.currentIndex) { _ in
            text = ""
            isFocused = true
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isFocused = true
            }
        }
    }

    private var borderColor: Color {
        guard viewModel.isAnswered else { return Color.white.opacity(0.12) }
        return viewModel.isCorrect == true ? Color(hex: "10B981") : Color(hex: "EF4444")
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isFocused = false
        viewModel.recallInput = text
        viewModel.submitRecallAnswer()
    }
}

// MARK: - Option Button Component

struct OptionButton: View {
    let option: QuizOption
    /// Context questions offer English words; meaning questions offer Korean
    /// glosses. The counterpart is revealed once the answer is in.
    let showsWordAsAnswer: Bool
    let isSelected: Bool
    let isCorrect: Bool
    let isAnswered: Bool
    let action: () -> Void

    private var primaryText: String {
        showsWordAsAnswer ? option.word : option.meaning.condensedMeaning()
    }

    private var secondaryText: String {
        showsWordAsAnswer ? option.meaning.condensedMeaning() : option.word
    }

    var body: some View {
        Button(action: {
            if !isAnswered {
                action()
            } else {
                AudioSynthesizer.shared.speak(text: option.word)
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryText)
                        .font(showsWordAsAnswer ? .system(size: 19, weight: .semibold, design: .rounded) : .body)
                        .fontWeight(showsWordAsAnswer ? .semibold : .medium)
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    // Reveal the counterpart (spelling or meaning) once answered
                    if isAnswered {
                        Text(showsWordAsAnswer ? secondaryText : "(\(secondaryText))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                // Status Icon
                if isAnswered {
                    if isCorrect {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.title3)
                    } else if isSelected {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.title3)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            // Keep the button at its ideal height even when the parent stack
            // runs out of vertical space — otherwise cornerRadius clips the
            // top and bottom of three-line content (2-line meaning + word)
            .fixedSize(horizontal: false, vertical: true)
            .background(backgroundColor)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: 1.5)
            )
            .scaleEffect(isSelected && isAnswered ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isAnswered)
        }
        .disabled(isAnswered)
    }

    // MARK: - Dynamic Styles

    private var textColor: Color {
        if isAnswered {
            if isCorrect || isSelected {
                return .white
            }
            return .white.opacity(0.3)
        }
        return .white.opacity(0.9)
    }

    private var backgroundColor: Color {
        if isAnswered {
            if isCorrect {
                return Color(hex: "10B981") // Green success
            }
            if isSelected {
                return Color(hex: "EF4444") // Red failure
            }
            return Color.white.opacity(0.01) // Inactive options
        }
        return Color.white.opacity(0.04) // Normal state
    }

    private var borderColor: Color {
        if isAnswered {
            if isCorrect {
                return Color(hex: "10B981")
            }
            if isSelected {
                return Color(hex: "EF4444")
            }
            return Color.white.opacity(0.04)
        }
        return Color.white.opacity(0.1)
    }
}
