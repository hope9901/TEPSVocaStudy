import SwiftUI

struct TypingPracticeView: View {
    @ObservedObject var viewModel: QuizSessionViewModel
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Header Info & Mode Switcher
            VStack(spacing: 12) {
                Image(systemName: viewModel.typingMode == .copyMode ? "keyboard.fill" : "ear.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundColor(Color(hex: "D946EF"))
                    .padding(.bottom, 2)
                    .animation(.spring(), value: viewModel.typingMode)
                
                Text(viewModel.typingMode == .copyMode ? "보고 따라 쓰며 암기하기" : "듣고 주관식 타이핑 암기하기")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(viewModel.typingMode == .copyMode ? "영어 단어와 뜻을 소리 내어 읽으면서 똑같이 입력하세요." : "들리는 영어 발음과 뜻을 단서로 스펠링을 직접 완성하세요.")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                
                // Mode Segmented Control
                Picker("타이핑 모드", selection: $viewModel.typingMode) {
                    Text("따라 쓰기").tag(QuizSessionViewModel.TypingMode.copyMode)
                    Text("블라인드 리스닝").tag(QuizSessionViewModel.TypingMode.blindMode)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .onChange(of: viewModel.typingMode) { newMode in
                    if newMode == .blindMode, let target = viewModel.currentTypingWord {
                        AudioSynthesizer.shared.speak(text: target.word)
                    }
                }
            }
            
            // Word Copy Card
            if let target = viewModel.currentTypingWord {
                VStack(spacing: 20) {
                    if viewModel.typingMode == .copyMode {
                        // English Word Visible for Copying
                        Text(target.word)
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundColor(Color(hex: "D946EF"))
                            .tracking(1.5)
                            .multilineTextAlignment(.center)
                    } else {
                        // Hides spelling, provides larger replay voice button
                        VStack(spacing: 12) {
                            Text(String(repeating: "_ ", count: target.word.count))
                                .font(.system(size: 32, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(hex: "D946EF"))
                                .multilineTextAlignment(.center)
                                .padding(.bottom, 4)
                            
                            Button(action: {
                                AudioSynthesizer.shared.speak(text: target.word)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "speaker.wave.3.fill")
                                    Text("발음 다시 듣기")
                                        .fontWeight(.bold)
                                }
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color(hex: "D946EF").opacity(0.15))
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color(hex: "D946EF").opacity(0.4), lineWidth: 1)
                                )
                            }
                        }
                    }
                    
                    // Korean Meaning
                    Text(target.meaning)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    // Nuance Example (If exists)
                    if let example = target.exampleSentence, !example.isEmpty {
                        Divider().background(Color.white.opacity(0.08))
                        
                        VStack(spacing: 6) {
                            Text("예문 뉘앙스")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(Color(hex: "D946EF").opacity(0.7))
                            
                            // Mask the target word inside the sentence if in blind mode
                            let displayExample = viewModel.typingMode == .copyMode ? 
                                example : 
                                example.replacingOccurrences(of: target.word, with: "______", options: .caseInsensitive)
                            
                            Text(displayExample)
                                .font(.subheadline)
                                .italic()
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                        }
                    }
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.02))
                .cornerRadius(28)
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            viewModel.isTypingSuccess ? Color(hex: "10B981") : Color.white.opacity(0.08),
                            lineWidth: viewModel.isTypingSuccess ? 2.0 : 1.0
                        )
                )
                .shadow(
                    color: viewModel.isTypingSuccess ? Color(hex: "10B981").opacity(0.2) : Color.clear,
                    radius: 12, x: 0, y: 0
                )
                .padding(.horizontal)
                
                // Typing Input Area
                VStack(spacing: 12) {
                    ZStack(alignment: .trailing) {
                        TextField(viewModel.typingMode == .copyMode ? "여기에 영어 단어를 입력하세요" : "들리는 단어의 스펠링을 입력하세요", text: $viewModel.typingInput)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .frame(height: 56)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(16)
                            .focused($isTextFieldFocused)
                            .submitLabel(.done)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        viewModel.isTypingSuccess ? Color(hex: "10B981") : Color.white.opacity(0.12),
                                        lineWidth: 1.5
                                    )
                            )
                            .onChange(of: viewModel.typingInput) { _ in
                                viewModel.handleTypingInputChanged()
                            }
                        
                        // Checkmark animation on success
                        if viewModel.isTypingSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(hex: "10B981"))
                                .font(.title3)
                                .padding(.trailing, 18)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .onAppear {
            // Auto focus keyboard on transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.isTextFieldFocused = true
            }
        }
    }
}
