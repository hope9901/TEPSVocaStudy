import SwiftUI

struct AddWordView: View {
    @StateObject private var viewModel = AddWordViewModel()
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ZStack {
                // Dark Background
                Color(hex: "0D0D1E").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Title
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("새 단어 추가하기")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                Text("통합 단어장에 단어를 추가하여 공부해보세요.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                        }
                        .padding(.top, 16)
                        
                        // Input Fields Panel
                        VStack(spacing: 20) {
                            // 1. English Word Input
                            VStack(alignment: .leading, spacing: 8) {
                                Text("영어 단어")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                TextField("예: commute", text: $viewModel.wordInput)
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(
                                                viewModel.isDuplicate ? Color(hex: "EF4444") : Color.white.opacity(0.1),
                                                lineWidth: 1
                                            )
                                    )
                                    .textInputAutocapitalization(.never)
                                    .disableAutocorrection(true)
                                
                                // Duplicate warning
                                if viewModel.isDuplicate {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                        Text("이미 데이터베이스에 존재하는 단어입니다.")
                                            .font(.caption)
                                    }
                                    .foregroundColor(Color(hex: "EF4444"))
                                    .padding(.leading, 2)
                                    .transition(.opacity)
                                }
                            }
                            
                            // 2. Korean Meaning Input
                            VStack(alignment: .leading, spacing: 8) {
                                Text("한글 뜻")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                TextField("예: 통근하다, 출퇴근하다", text: $viewModel.meaningInput)
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            
                            // 3. Example Sentence Input
                            VStack(alignment: .leading, spacing: 8) {
                                Text("뉘앙스 예문 (선택)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                TextEditor(text: $viewModel.exampleInput)
                                    .font(.body)
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .frame(height: 100)
                                    .background(Color.white.opacity(0.04))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                    .onAppear {
                                        // UITextView background transparency fallback
                                        UITextView.appearance().backgroundColor = .clear
                                    }
                            }
                        }
                        .padding(20)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                        
                        // Autocomplete Search Results (Dynamic panel)
                        if !viewModel.searchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("연관 검색 단어 (DB 목록)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(Color(hex: "818CF8"))
                                
                                VStack(spacing: 0) {
                                    ForEach(viewModel.searchResults) { item in
                                        Button(action: {
                                            // Auto-fill form with existing word to view details
                                            viewModel.wordInput = item.word
                                            viewModel.meaningInput = item.meaning
                                            viewModel.exampleInput = item.exampleSentence ?? ""
                                        }) {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(item.word)
                                                        .font(.body)
                                                        .fontWeight(.bold)
                                                        .foregroundColor(.white)
                                                    Text(item.meaning)
                                                        .font(.caption)
                                                        .foregroundColor(.gray)
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                                
                                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            .padding(.vertical, 12)
                                            .padding(.horizontal, 14)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.white.opacity(viewModel.wordInput.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == item.word.lowercased() ? 0.08 : 0.01))
                                        }
                                        
                                        if item.id != viewModel.searchResults.last?.id {
                                            Divider().background(Color.white.opacity(0.06))
                                        }
                                    }
                                }
                                .background(Color.white.opacity(0.02))
                                .cornerRadius(14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .transition(.opacity)
                        }
                        
                        // Error message
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .foregroundColor(Color(hex: "EF4444"))
                                .font(.subheadline)
                                .padding(.horizontal)
                        }
                        
                        // Submit Button
                        Button(action: {
                            viewModel.addWord()
                        }) {
                            Text("단어 추가하기")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(
                                    viewModel.isDuplicate ?
                                    AnyView(Color.white.opacity(0.05)) :
                                    AnyView(LinearGradient(
                                        colors: [Color(hex: "6366F1"), Color(hex: "4F46E5")],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                )
                                .cornerRadius(14)
                                .shadow(color: viewModel.isDuplicate ? Color.clear : Color(hex: "6366F1").opacity(0.2), radius: 8, x: 0, y: 4)
                        }
                        .disabled(viewModel.isDuplicate)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("취소") {
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(Color(hex: "818CF8"))
            )
            .alert(isPresented: $viewModel.showSuccessAlert) {
                Alert(
                    title: Text("추가 완료"),
                    message: Text("단어가 데이터베이스에 성공적으로 저장되었습니다."),
                    dismissButton: .default(Text("확인"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
