import SwiftUI

struct QuizView: View {
    @ObservedObject var viewModel: QuizSessionViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Word Card
            if let target = viewModel.currentWord {
                VStack(spacing: 20) {
                    // English Word & Audio Icon
                    HStack(spacing: 12) {
                        Text(target.word)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.6)
                            .lineLimit(2)
                        
                        Button(action: {
                            AudioSynthesizer.shared.speak(text: target.word)
                        }) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                                .foregroundColor(Color(hex: "818CF8"))
                                .padding(10)
                                .background(Color(hex: "818CF8").opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                    
                    // Display example sentence dynamically
                    // Show it when user gets it wrong (as a hint/nuance) or after answering
                    if let sentence = target.exampleSentence, !sentence.isEmpty {
                        VStack(spacing: 8) {
                            Text("뉘앙스 예문")
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
                                .padding(.horizontal)
                        }
                        .padding(.top, 10)
                        .opacity(viewModel.isAnswered ? 1.0 : 0.25) // Partially visible as hint before answering
                        .animation(.easeIn, value: viewModel.isAnswered)
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
            }
            
            Spacer()
            
            // Multiple Choice Options (4-choice Distractors)
            VStack(spacing: 14) {
                ForEach(viewModel.options) { option in
                    OptionButton(
                        option: option,
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
}

// MARK: - Option Button Component

struct OptionButton: View {
    let option: QuizOption
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
                    Text(option.meaning)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.8)
                    
                    // Reveal the English spelling for the incorrect distractor meanings
                    if isAnswered && !isCorrect {
                        Text("(\(option.word))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
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
