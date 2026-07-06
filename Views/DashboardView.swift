import SwiftUI

struct DashboardView: View {
    @State private var totalCount: Int = 0
    @State private var familiarCount: Int = 0
    @State private var unfamiliarCount: Int = 0
    @State private var hardCount: Int = 0
    @State private var distribution: ScheduleDistribution = ScheduleDistribution(todayOrOverdue: 0, within3Days: 0, within7Days: 0, within30Days: 0, over30Days: 0)
    
    @State private var showQuizSession = false
    @State private var showAddWord = false
    @State private var isHardWordsMode = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background Gradient
                LinearGradient(
                    gradient: Gradient(colors: [Color(hex: "0D0D1E"), Color(hex: "1A1A2E"), Color(hex: "121212")]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // Light glow effects
                VStack {
                    HStack {
                        Circle()
                            .fill(Color(hex: "6366F1").opacity(0.15))
                            .frame(width: 250, height: 250)
                            .blur(radius: 80)
                            .offset(x: -80, y: -50)
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color(hex: "D946EF").opacity(0.15))
                            .frame(width: 280, height: 280)
                            .blur(radius: 90)
                            .offset(x: 100, y: 100)
                    }
                }
                .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        // Header
                        VStack(spacing: 6) {
                            Text("TEPS Voca Study")
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(hex: "818CF8"), Color(hex: "F472B6")],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            Text("에빙하우스 망각곡선 & 순환 타이핑 암기")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .fontWeight(.medium)
                        }
                        .padding(.top, 24)
                        
                        // Progress Panel (Glassmorphism)
                        VStack(spacing: 16) {
                            Text("내 학습 현황")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Progress bar
                            let progressRatio = totalCount > 0 ? Double(familiarCount) / Double(totalCount) : 0.0
                            VStack(spacing: 8) {
                                HStack {
                                    Text("암기 완료율")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                    Spacer()
                                    Text("\(Int(progressRatio * 100))%")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(Color(hex: "818CF8"))
                                }
                                
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 10)
                                        
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color(hex: "6366F1"), Color(hex: "EC4899")],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                            .frame(width: geo.size.width * CGFloat(progressRatio), height: 10)
                                            .shadow(color: Color(hex: "6366F1").opacity(0.4), radius: 5, x: 0, y: 0)
                                    }
                                }
                                .frame(height: 10)
                            }
                        }
                        .padding(20)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        
                        // Statistics Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            StatCard(title: "총 단어 수", value: "\(totalCount)", icon: "books.vertical.fill", color: Color(hex: "60A5FA"))
                            StatCard(title: "외운 단어", value: "\(familiarCount)", icon: "checkmark.circle.fill", color: Color(hex: "34D399"))
                            StatCard(title: "미완료 단어", value: "\(unfamiliarCount)", icon: "hourglass.badge.plus", color: Color(hex: "FBBF24"))
                            StatCard(title: "난공불락 단어", value: "\(hardCount)", icon: "exclamationmark.triangle.fill", color: Color(hex: "F87171"))
                        }
                        .padding(.horizontal)
                        
                        // Spaced Repetition Distribution Panel
                        VStack(spacing: 16) {
                            HStack {
                                Image(systemName: "chart.bar.xaxis")
                                    .foregroundColor(Color(hex: "818CF8"))
                                Text("에빙하우스 복습 예정 분포")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            
                            let maxVal = max(1, max(distribution.todayOrOverdue, max(distribution.within3Days, max(distribution.within7Days, max(distribution.within30Days, distribution.over30Days)))))
                            
                            VStack(spacing: 12) {
                                scheduleRow(title: "오늘/미룬 복습", count: distribution.todayOrOverdue, maxVal: maxVal, color: Color(hex: "F87171"))
                                scheduleRow(title: "3일 이내 복습", count: distribution.within3Days, maxVal: maxVal, color: Color(hex: "D946EF"))
                                scheduleRow(title: "7일 이내 복습", count: distribution.within7Days, maxVal: maxVal, color: Color(hex: "60A5FA"))
                                scheduleRow(title: "30일 이내 복습", count: distribution.within30Days, maxVal: maxVal, color: Color(hex: "34D399"))
                                scheduleRow(title: "안정기 (30일 초과)", count: distribution.over30Days, maxVal: maxVal, color: Color.white.opacity(0.4))
                            }
                        }
                        .padding(20)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .padding(.horizontal)
                        
                        // Action Buttons
                        VStack(spacing: 16) {
                            // Primary Start Button
                            Button(action: {
                                isHardWordsMode = false
                                showQuizSession = true
                            }) {
                                HStack {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                    Text("100단어 순환 학습 시작")
                                        .font(.headline)
                                        .fontWeight(.bold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    LinearGradient(
                                        colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .cornerRadius(16)
                                .shadow(color: Color(hex: "6366F1").opacity(0.3), radius: 10, x: 0, y: 5)
                            }
                            
                            // Hard Words Button
                            Button(action: {
                                if hardCount > 0 {
                                    isHardWordsMode = true
                                    showQuizSession = true
                                }
                            }) {
                                HStack {
                                    Image(systemName: "flame.fill")
                                        .font(.title3)
                                    Text("난공불락 집중 훈련 (\(hardCount))")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(hardCount > 0 ? .white : .gray)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    hardCount > 0 ?
                                    AnyView(LinearGradient(
                                        colors: [Color(hex: "EF4444"), Color(hex: "B91C1C")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )) :
                                    AnyView(Color.white.opacity(0.05))
                                )
                                .cornerRadius(16)
                                .shadow(color: hardCount > 0 ? Color(hex: "EF4444").opacity(0.2) : Color.clear, radius: 8, x: 0, y: 4)
                            }
                            .disabled(hardCount == 0)
                            
                            // Add Word Button
                            Button(action: {
                                showAddWord = true
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                    Text("새로운 단어 등록하기")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                refreshStats()
            }
            // Navigation Sheets
            .fullScreenCover(isPresented: $showQuizSession, onDismiss: { refreshStats() }) {
                QuizSessionView(isHardWords: isHardWordsMode)
            }
            .sheet(isPresented: $showAddWord, onDismiss: { refreshStats() }) {
                AddWordView()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func refreshStats() {
        let stats = DatabaseManager.shared.fetchStatistics()
        self.totalCount = stats.total
        self.familiarCount = stats.familiar
        self.unfamiliarCount = stats.unfamiliar
        self.hardCount = stats.hard
        
        self.distribution = DatabaseManager.shared.fetchScheduleDistribution()
    }
    
    private func scheduleRow(title: String, count: Int, maxVal: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Text("\(count)개")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 6)
                    
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(Double(count) / Double(maxVal)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Subviews

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fontWeight(.medium)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Color Hex Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 1)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
