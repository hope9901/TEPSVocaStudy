import SwiftUI

struct DashboardView: View {
    @State private var totalCount: Int = 0
    @State private var familiarCount: Int = 0
    @State private var unfamiliarCount: Int = 0
    @State private var hardCount: Int = 0
    @State private var distribution: ScheduleDistribution = ScheduleDistribution(todayOrOverdue: 0, within3Days: 0, within7Days: 0, within30Days: 0, over30Days: 0)

    // SRS state, today's activity and recent accuracy
    @State private var stateCounts: LearningStateCounts = .zero
    @State private var todaySummary: TodayStudySummary = .zero
    @State private var recentPerformance: RecentPerformance = .empty
    @State private var availableDue: Int = 0
    @State private var availableNew: Int = 0

    @State private var showQuizSession = false
    @State private var showAddWord = false
    @State private var isHardWordsMode = false

    // Session preferences (persisted)
    @AppStorage("studyMode") private var studyModeRaw: String = StudyMode.mixed.rawValue
    @AppStorage("newWordsPerSession") private var newWordsPerSession: Int = SRSConfiguration.default.newWordsPerSession

    private var studyMode: StudyMode {
        StudyMode(rawValue: studyModeRaw) ?? .mixed
    }

    /// What a session started right now would actually contain.
    private var plannedDue: Int { min(availableDue, SRSConfiguration.default.maxDuePerSession) }
    private var plannedNew: Int {
        min(availableNew, min(newWordsPerSession, max(0, SRSConfiguration.default.maxSessionSize - plannedDue)))
    }
    private var plannedTotal: Int { plannedDue + plannedNew }
    
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
                        
                        // Today's study panel
                        todayPanel
                            .padding(.horizontal)

                        // Statistics Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            StatCard(title: "총 단어 수", value: "\(totalCount)", icon: "books.vertical.fill", color: Color(hex: "60A5FA"))
                            StatCard(title: "외운 단어", value: "\(familiarCount)", icon: "checkmark.circle.fill", color: Color(hex: "34D399"))
                            StatCard(title: "미완료 단어", value: "\(unfamiliarCount)", icon: "hourglass.badge.plus", color: Color(hex: "FBBF24"))
                            StatCard(title: "난공불락 단어", value: "\(hardCount)", icon: "exclamationmark.triangle.fill", color: Color(hex: "F87171"))
                        }
                        .padding(.horizontal)
                        
                        // Learning state distribution (NEW / LEARNING / DUE / MASTERED)
                        learningStatePanel
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
                        
                        // Recent accuracy by question type
                        accuracyPanel
                            .padding(.horizontal)

                        // Session composition settings
                        sessionSettingsPanel
                            .padding(.horizontal)

                        // Action Buttons
                        VStack(spacing: 16) {
                            // Primary Start Button — labelled with the real
                            // number of questions the session will contain.
                            Button(action: {
                                guard plannedTotal > 0 else { return }
                                isHardWordsMode = false
                                showQuizSession = true
                            }) {
                                VStack(spacing: 2) {
                                    HStack {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title2)
                                        Text(plannedTotal > 0 ? "오늘의 학습 시작 (\(plannedTotal)문항)" : "오늘 학습할 단어가 없습니다")
                                            .font(.headline)
                                            .fontWeight(.bold)
                                    }
                                    if plannedTotal > 0 {
                                        Text("복습 \(plannedDue) · 신규 \(plannedNew)")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.85))
                                    }
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 64)
                                .background(
                                    plannedTotal > 0 ?
                                    AnyView(LinearGradient(
                                        colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )) :
                                    AnyView(Color.white.opacity(0.05))
                                )
                                .cornerRadius(16)
                                .shadow(color: plannedTotal > 0 ? Color(hex: "6366F1").opacity(0.3) : Color.clear, radius: 10, x: 0, y: 5)
                            }
                            .disabled(plannedTotal == 0)
                            
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
                QuizSessionView(
                    isHardWords: isHardWordsMode,
                    studyMode: studyMode,
                    newWordsPerSession: newWordsPerSession
                )
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

        self.stateCounts = DatabaseManager.shared.fetchLearningStateCounts()
        self.todaySummary = DatabaseManager.shared.fetchTodaySummary()
        self.recentPerformance = DatabaseManager.shared.fetchRecentPerformance(days: 7)

        let available = DatabaseManager.shared.fetchAvailableCounts()
        self.availableDue = available.due
        self.availableNew = available.new
    }
    
    // MARK: - New Panels

    /// What happened today. Graded reviews and same-session corrections are
    /// deliberately shown as separate numbers — a day of re-quizzing is not a
    /// day of retention.
    private var todayPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(Color(hex: "FBBF24"))
                Text("오늘의 학습")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            HStack(spacing: 10) {
                miniStat(title: "신규", value: todaySummary.newIntroduced, color: Color(hex: "60A5FA"))
                miniStat(title: "복습", value: todaySummary.dueReviewed, color: Color(hex: "818CF8"))
                miniStat(title: "복습 성공", value: todaySummary.reviewSuccess, color: Color(hex: "34D399"))
                miniStat(title: "복습 실패", value: todaySummary.reviewFail, color: Color(hex: "F87171"))
            }

            if todaySummary.correctionAttempts > 0 {
                HStack {
                    Text("세션 내 교정 (같은 날 재시험)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(todaySummary.correctionSuccess) / \(todaySummary.correctionAttempts)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "D946EF"))
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.03))
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// NEW / LEARNING / DUE / MASTERED.
    private var learningStatePanel: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "circle.grid.2x2.fill")
                    .foregroundColor(Color(hex: "818CF8"))
                Text("단어 상태 분포")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            HStack(spacing: 10) {
                ForEach(WordLearningState.allCases, id: \.self) { state in
                    miniStat(title: state.badge, value: stateCounts.count(for: state), color: color(for: state))
                }
            }

            Text("DUE는 오늘 복습할 단어, NEW는 아직 한 번도 학습하지 않은 단어입니다. 복습일이 남은 단어는 세션에 출제되지 않으며, MASTERED는 문맥·스펠링 문제까지 맞힌 단어만 해당합니다.")
                .font(.caption2)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Color.white.opacity(0.03))
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Last 7 days, split by what each question type actually measured.
    private var accuracyPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "target")
                    .foregroundColor(Color(hex: "34D399"))
                Text("최근 7일 유형별 정확도")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(recentPerformance.modeAccuracies) { accuracy in
                    accuracyRow(
                        title: accuracy.mode.displayName,
                        correct: accuracy.correct,
                        total: accuracy.total,
                        color: color(for: accuracy.mode)
                    )
                }

                Divider().background(Color.white.opacity(0.08))

                accuracyRow(
                    title: "같은 세션 재시험 (교정)",
                    correct: recentPerformance.correctionCorrect,
                    total: recentPerformance.correctionTotal,
                    color: Color(hex: "D946EF")
                )

                Text("위 세 유형은 복습일에 치른 장기 기억 측정치이고, 맨 아래 교정 정답률은 같은 세션 안에서 다시 맞힌 비율입니다. 두 값은 섞이지 않습니다.")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.03))
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Session composition controls: question types and how many new words to
    /// introduce. The session length follows from these plus what is actually due.
    private var sessionSettingsPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(Color(hex: "F472B6"))
                Text("학습 설정")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("출제 유형")
                    .font(.caption)
                    .foregroundColor(.gray)
                Picker("출제 유형", selection: $studyModeRaw) {
                    ForEach(StudyMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                Text(studyModeDescription)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("세션당 신규 단어")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(newWordsPerSession)개")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "818CF8"))
                }
                Picker("세션당 신규 단어", selection: $newWordsPerSession) {
                    ForEach([0, 10, 20, 30, 50], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.03))
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var studyModeDescription: String {
        switch studyMode {
        case .mixed:
            return "단어 숙련도에 따라 의미 → 문맥 빈칸 → 스펠링 입력 순으로 자동 전환합니다."
        case .meaningOnly:
            return "영어 단어를 보고 한국어 뜻을 고르는 기존 방식만 출제합니다."
        case .contextOnly:
            return "TEPS처럼 문장 빈칸에 알맞은 단어를 고릅니다. 예문이 없는 단어는 의미 문제로 출제됩니다."
        }
    }

    private func color(for state: WordLearningState) -> Color {
        switch state {
        case .new: return Color(hex: "60A5FA")
        case .learning: return Color(hex: "FBBF24")
        case .due: return Color(hex: "F87171")
        case .mastered: return Color(hex: "34D399")
        }
    }

    private func color(for mode: StudyQuestionMode) -> Color {
        switch mode {
        case .meaning: return Color(hex: "60A5FA")
        case .context: return Color(hex: "818CF8")
        case .recall: return Color(hex: "34D399")
        }
    }

    private func miniStat(title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(14)
    }

    private func accuracyRow(title: String, correct: Int, total: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Text(total > 0 ? "\(Int((Double(correct) / Double(total)) * 100))%  (\(correct)/\(total))" : "기록 없음")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(total > 0 ? .white : .gray)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 6)
                    Capsule()
                        .fill(color)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(Double(correct) / Double(total)) : 0, height: 6)
                }
            }
            .frame(height: 6)
        }
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
