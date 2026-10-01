import SwiftUI

struct QuizView: View {
    @ObservedObject var viewModel: QuizSessionViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            // Word Card (scrolls when a long example sentence exceeds the space
            // left over by the answer options, instead of truncating the text)
            if let item = viewModel.currentItem {
                ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    if item.quizType == .context, let blanked = item.blankedSentence {
                        contextQuestion(item: item, blanked: blanked)
                    } else {
                        meaningQuestion(target: item.corpus)
                    }
                }
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

            // Multiple Choice Options (4-choice Distractors)
            VStack(spacing: 14) {
                ForEach(viewModel.options) { option in
                    OptionButton(
                        option: option,
                        quizType: viewModel.currentItem?.quizType ?? .meaning,
                        isSelected: viewModel.selectedAnswer?.id == option.id,
                        isCorrect: viewModel.currentItem?.corpus.id == option.corpusId,
                        isAnswered: viewModel.isAnswered,
                        action: {
                            viewModel.submitAnswer(option: option)
                        }
                    )
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Next Question Button
            if viewModel.isAnswered {
                Button(action: {
                    viewModel.nextQuestion()
                }) {
                    HStack {
                        Text(viewModel.currentIndex == viewModel.currentItems.count - 1 ? "결과 보기" : "다음 단어로")
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

    // MARK: - Meaning question (English word → Korean meaning)

    @ViewBuilder
    private func meaningQuestion(target: Corpus) -> some View {
        HStack(spacing: 12) {
            Text(target.word)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(2)

            speakButton(target.word)
        }

        // The example sentence gives away the meaning, so it only appears after answering.
        if viewModel.isAnswered, let sentence = target.exampleSentence, !sentence.isEmpty {
            exampleBlock(title: "뉘앙스 예문", sentence: sentence)
                .transition(.opacity)
        }
    }

    // MARK: - Context question (sentence with a blank → English word)

    @ViewBuilder
    private func contextQuestion(item: SessionItem, blanked: String) -> some View {
        Text("TEPS 문맥 · 빈칸에 알맞은 단어는?")
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(Color(hex: "F59E0B"))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(hex: "F59E0B").opacity(0.12))
            .cornerRadius(8)

        Text(viewModel.isAnswered ? (item.corpus.exampleSentence ?? blanked) : blanked)
            .font(.title3)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)

        // Pronouncing the word before answering would reveal it.
        if viewModel.isAnswered {
            HStack(spacing: 10) {
                Text("\(item.corpus.word)  ·  \(item.corpus.meaning.condensedMeaning())")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(Color(hex: "34D399"))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                speakButton(item.corpus.word)
            }
            .transition(.opacity)
        }
    }

    private func speakButton(_ word: String) -> some View {
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

    private func exampleBlock(title: String, sentence: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(Color(hex: "818CF8").opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "818CF8").opacity(0.1))
                .cornerRadius(6)

            Text(sentence)
                .font(.subheadline)
                .italic()
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)
        }
        .padding(.top, 10)
    }
}

// MARK: - Option Button Component

struct OptionButton: View {
    let option: QuizOption
    let quizType: QuizType
    let isSelected: Bool
    let isCorrect: Bool
    let isAnswered: Bool
    let action: () -> Void
    
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
                    if quizType == .context {
                        // Context: options are English words; meanings are revealed after answering
                        Text(option.word)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        if isAnswered {
                            Text(option.meaning.condensedMeaning())
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(textColor.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(option.meaning.condensedMeaning())
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        // Reveal the English spelling for the incorrect distractor meanings
                        if isAnswered && !isCorrect {
                            Text("(\(option.word))")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(textColor.opacity(0.7))
                                .lineLimit(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
