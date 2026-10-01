import SwiftUI

/// What the dashboard asks QuizSessionView to run.
struct SessionRequest: Identifiable {
    let id = UUID()
    let mode: StudyMode
    var extraNewWords: Int = 0
}

struct DashboardView: View {
    @State private var totalCount: Int = 0
    @State private var hardCount: Int = 0
    @State private var states = StateCounts()
    @State private var today = TodayStats()
    @State private var accuracy = AccuracyReport()
    @State private var distribution: ScheduleDistribution = ScheduleDistribution(todayOrOverdue: 0, within3Days: 0, within7Days: 0, within30Days: 0, over30Days: 0)
    @State private var dailyNewLimit: Int = SessionPlanner.dailyNewLimit()

    @State private var sessionRequest: SessionRequest?
    @State private var showAddWord = false

    /// Today's session size: due reviews (capped per session) + remaining new quota.
    private var plannedDue: Int { min(today.dueRemaining, SessionPlanner.maxSessionSize) }
    private var plannedNew: Int { min(today.newRemaining, SessionPlanner.maxSessionSize - plannedDue) }
    private var hasWorkToday: Bool { plannedDue + plannedNew > 0 }

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

                        todayPanel
                        actionButtons
                        statePanel
                        accuracyPanel
                        distributionPanel
                        secondaryButtons
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                refreshStats()
            }
            // Navigation Sheets
            .fullScreenCover(item: $sessionRequest, onDismiss: { refreshStats() }) { request in
                QuizSessionView(mode: request.mode, extraNewWords: request.extraNewWords)
            }
            .sheet(isPresented: $showAddWord, onDismiss: { refreshStats() }) {
                AddWordView()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Panels

    private var todayPanel: some View {
        panel {
            HStack {
                Text("오늘")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(hasWorkToday ? "학습 예정 \(plannedDue + plannedNew)문제" : "오늘 학습 완료")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(hasWorkToday ? Color(hex: "818CF8") : Color(hex: "34D399"))
            }

            HStack(spacing: 10) {
                miniStat("신규 학습", "\(today.newStudied)", Color(hex: "60A5FA"))
                miniStat("복습 남음", "\(today.dueRemaining)", Color(hex: "F87171"))
                miniStat("복습 성공", "\(today.reviewCorrect)", Color(hex: "34D399"))
                miniStat("복습 실패", "\(today.reviewWrong)", Color(hex: "FBBF24"))
            }

            HStack {
                Text("하루 신규 단어")
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Stepper(value: $dailyNewLimit, in: 5...100, step: 5) {
                    Text("\(dailyNewLimit)개")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .fixedSize()
                .onChange(of: dailyNewLimit) { newValue in
                    UserDefaults.standard.set(newValue, forKey: SessionPlanner.dailyNewLimitKey)
                    refreshStats()
                }
            }
        }
    }

    private var statePanel: some View {
        VStack(spacing: 16) {
            // MASTERED needs a long interval and a correct context answer — not just recognition.
            let masteredRatio = totalCount > 0 ? Double(states.mastered) / Double(totalCount) : 0.0
            panel {
                HStack {
                    Text("마스터 비율")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(Int(masteredRatio * 100))%  (\(states.mastered) / \(totalCount))")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(Color(hex: "818CF8"))
                }
                progressBar(ratio: masteredRatio)
                Text("마스터 = 14일 이상 간격 유지 + TEPS 문맥 문제 정답 경험")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                StatCard(title: "NEW · 미학습", value: "\(states.new)", icon: "sparkles", color: Color(hex: "60A5FA"))
                StatCard(title: "DUE · 오늘 복습", value: "\(states.due)", icon: "clock.badge.exclamationmark.fill", color: Color(hex: "F87171"))
                StatCard(title: "LEARNING · 학습 중", value: "\(states.learning)", icon: "hourglass.badge.plus", color: Color(hex: "FBBF24"))
                StatCard(title: "MASTERED · 마스터", value: "\(states.mastered)", icon: "checkmark.seal.fill", color: Color(hex: "34D399"))
            }
            .padding(.horizontal)
        }
    }

    private var accuracyPanel: some View {
        panel {
            HStack {
                Image(systemName: "target")
                    .foregroundColor(Color(hex: "818CF8"))
                Text("최근 7일 정확도")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            Text("첫 시도 기준 (신규·예정된 복습). 같은 세션 재시험은 따로 집계합니다.")
                .font(.caption2)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)

            accuracyRow("뜻 인식 (영→한)", accuracy.meaning, color: Color(hex: "818CF8"))
            accuracyRow("TEPS 문맥 (빈칸→단어)", accuracy.context, color: Color(hex: "F59E0B"))
            accuracyRow("회상 (블라인드 타이핑, 힌트 없이)", accuracy.recall, color: Color(hex: "D946EF"))
            Divider().background(Color.white.opacity(0.08))
            accuracyRow("같은 세션 오답 재시험", accuracy.sessionRetest, color: Color.white.opacity(0.4))
        }
    }

    private var distributionPanel: some View {
        // Spaced Repetition Distribution Panel (studied words only)
        panel {
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
    }

    // MARK: - Buttons

    private var actionButtons: some View {
        VStack(spacing: 14) {
            if hasWorkToday {
                primaryButton(
                    title: "오늘의 학습 시작",
                    subtitle: "복습 \(plannedDue) · 신규 \(plannedNew)",
                    icon: "play.circle.fill",
                    colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")]
                ) {
                    sessionRequest = SessionRequest(mode: .meaning)
                }

                primaryButton(
                    title: "TEPS 문맥 모드",
                    subtitle: "같은 단어를 예문 빈칸으로",
                    icon: "text.badge.checkmark",
                    colors: [Color(hex: "F59E0B"), Color(hex: "D97706")]
                ) {
                    sessionRequest = SessionRequest(mode: .context)
                }
            } else if states.new > 0 {
                // Today is done; more new words only on explicit request — never
                // by re-serving words whose review date has not arrived.
                let extra = min(dailyNewLimit, states.new)
                primaryButton(
                    title: "신규 단어 \(extra)개 더 학습",
                    subtitle: "오늘 복습·신규 한도 완료",
                    icon: "plus.circle.fill",
                    colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")]
                ) {
                    sessionRequest = SessionRequest(mode: .meaning, extraNewWords: extra)
                }
                primaryButton(
                    title: "신규 \(extra)개 · TEPS 문맥 모드",
                    subtitle: "새 단어를 예문 빈칸으로",
                    icon: "text.badge.plus",
                    colors: [Color(hex: "F59E0B"), Color(hex: "D97706")]
                ) {
                    sessionRequest = SessionRequest(mode: .context, extraNewWords: extra)
                }
            }
        }
        .padding(.horizontal)
    }

    private var secondaryButtons: some View {
        VStack(spacing: 16) {
            // Hard Words Button
            Button(action: {
                if hardCount > 0 {
                    sessionRequest = SessionRequest(mode: .hardWords)
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

    // MARK: - Data

    private func refreshStats() {
        let db = DatabaseManager.shared
        let now = Date()
        let stats = db.fetchStatistics()
        self.totalCount = stats.total
        self.hardCount = stats.hard
        self.states = db.fetchStateCounts(now: now)
        self.today = db.fetchTodayStats(now: now, dailyNewLimit: dailyNewLimit)
        self.accuracy = db.fetchAccuracyReport(now: now)
        self.distribution = db.fetchScheduleDistribution(now: now)
    }

    // MARK: - Building blocks

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14, content: content)
            .padding(20)
            .background(Color.white.opacity(0.03))
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal)
    }

    private func miniStat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }

    private func progressBar(ratio: Double) -> some View {
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
                    .frame(width: geo.size.width * CGFloat(ratio), height: 10)
                    .shadow(color: Color(hex: "6366F1").opacity(0.4), radius: 5, x: 0, y: 0)
            }
        }
        .frame(height: 10)
    }

    private func accuracyRow(_ title: String, _ value: Accuracy, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Text(value.ratio.map { "\(Int(($0 * 100).rounded()))%  (\(value.correct)/\(value.total))" } ?? "기록 없음")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.05)).frame(height: 6)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(value.ratio ?? 0), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func primaryButton(title: String, subtitle: String, icon: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.bold)
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .cornerRadius(16)
            .shadow(color: (colors.first ?? .clear).opacity(0.3), radius: 10, x: 0, y: 5)
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
