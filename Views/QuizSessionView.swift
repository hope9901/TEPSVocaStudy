import SwiftUI

struct QuizSessionView: View {
    @StateObject private var viewModel = QuizSessionViewModel()
    @Environment(\.presentationMode) var presentationMode
    
    let isHardWords: Bool
    
    var body: some View {
        ZStack {
            // Dark Background
            Color(hex: "0D0D1E").ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Navigation/Progress bar
                if viewModel.phase != .finished {
                    sessionHeader
                }
                
                // Main Content Switching
                ZStack {
                    switch viewModel.phase {
                    case .mainQuiz, .reQuiz:
                        QuizView(viewModel: viewModel)
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                    case .typingReview:
                        TypingPracticeView(viewModel: viewModel)
                            .transition(.opacity)
                    case .finished:
                        SessionCompletedView(viewModel: viewModel) {
                            presentationMode.wrappedValue.dismiss()
                        }
                        .transition(.scale)
                    }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: viewModel.phase)
            }
        }
        .onAppear {
            viewModel.startSession(isHardWords: isHardWords)
        }
    }
    
    // MARK: - Header Component
    
    private var sessionHeader: some View {
        VStack(spacing: 12) {
            HStack {
                // Phase Indicator Label
                HStack(spacing: 6) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 8, height: 8)
                    Text(phaseTitle)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .cornerRadius(12)
                
                Spacer()
                
                // Item counter
                Text("\(viewModel.currentIndex + 1) / \(totalItemsCount)")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                
                Spacer()
                
                // Close button
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.body)
                        .foregroundColor(.gray)
                        .padding(8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)
            
            // Progress Bar
            let progress = Double(viewModel.currentIndex) / Double(max(1, totalItemsCount))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(phaseGradient)
                        .frame(width: geo.size.width * CGFloat(progress))
                        .shadow(color: phaseColor.opacity(0.3), radius: 4, x: 0, y: 0)
                }
            }
            .frame(height: 6)
            .padding(.horizontal)
            .animation(.spring(), value: viewModel.currentIndex)
        }
        .padding(.bottom, 8)
        .background(Color(hex: "0D0D1E").shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 2))
    }
    
    // MARK: - Helper Properties
    
    private var phaseTitle: String {
        switch viewModel.phase {
        case .mainQuiz:
            return viewModel.isHardWordsSession ? "난공불락 집중 학습" : "1단계: 100단어 퀴즈"
        case .typingReview:
            return "2단계: 오답 따라 쓰기"
        case .reQuiz:
            return "3단계: 오답 재퀴즈"
        case .finished:
            return "완료"
        }
    }
    
    private var phaseColor: Color {
        switch viewModel.phase {
        case .mainQuiz:
            return Color(hex: "6366F1")
        case .typingReview:
            return Color(hex: "D946EF")
        case .reQuiz:
            return Color(hex: "3B82F6")
        case .finished:
            return Color(hex: "10B981")
        }
    }
    
    private var phaseGradient: LinearGradient {
        switch viewModel.phase {
        case .mainQuiz:
            return LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "818CF8")], startPoint: .leading, endPoint: .trailing)
        case .typingReview:
            return LinearGradient(colors: [Color(hex: "D946EF"), Color(hex: "F472B6")], startPoint: .leading, endPoint: .trailing)
        case .reQuiz:
            return LinearGradient(colors: [Color(hex: "3B82F6"), Color(hex: "60A5FA")], startPoint: .leading, endPoint: .trailing)
        case .finished:
            return LinearGradient(colors: [Color(hex: "10B981"), Color(hex: "34D399")], startPoint: .leading, endPoint: .trailing)
        }
    }
    
    private var totalItemsCount: Int {
        switch viewModel.phase {
        case .mainQuiz, .reQuiz:
            return viewModel.currentWords.count
        case .typingReview:
            return viewModel.incorrectWords.count
        case .finished:
            return 0
        }
    }
}

// MARK: - Completed Celebration View

struct SessionCompletedView: View {
    @ObservedObject var viewModel: QuizSessionViewModel
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Celebration Icon
            ZStack {
                Circle()
                    .fill(Color(hex: "10B981").opacity(0.15))
                    .frame(width: 140, height: 140)
                
                Circle()
                    .fill(Color(hex: "10B981").opacity(0.3))
                    .frame(width: 110, height: 110)
                
                Image(systemName: "trophy.fill")
                    .font(.system(size: 54))
                    .foregroundColor(Color(hex: "34D399"))
                    .shadow(color: Color(hex: "10B981").opacity(0.5), radius: 8, x: 0, y: 4)
            }
            
            // Text Header
            VStack(spacing: 8) {
                Text("학습 완료!")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                
                Text(viewModel.isHardWordsSession ? "자주 틀리던 단어를 완벽히 정복했습니다." : "오늘의 100단어 세션을 모두 암기했습니다!")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            // Statistics Summary Card (Glassmorphism)
            VStack(spacing: 16) {
                HStack {
                    Text("총 학습 단어")
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(viewModel.totalSessionWordsCount)개")
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.08))
                
                HStack {
                    Text("오답 타이핑 수")
                        .foregroundColor(.gray)
                    Spacer()
                    // If no incorrect words in history, it's 100% first-try
                    Text("완벽 암기 완료")
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "34D399"))
                }
            }
            .padding(20)
            .background(Color.white.opacity(0.03))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 32)
            
            Spacer()
            
            // Confirm Button
            Button(action: onDismiss) {
                Text("대시보드로 돌아가기")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "34D399"), Color(hex: "10B981")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                    .shadow(color: Color(hex: "10B981").opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }
}
