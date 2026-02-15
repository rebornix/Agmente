import SwiftUI
import ACPClient

// MARK: - Data Models

struct UserInputOption: Equatable, Identifiable {
    let id = UUID()
    let label: String
    let description: String?
    let isOther: Bool
    let isSecret: Bool
}

struct UserInputQuestion: Equatable, Identifiable {
    let id: String
    let header: String
    let text: String
    let options: [UserInputOption]
    let multiSelect: Bool
}

struct PendingUserInputRequest: Equatable, Identifiable {
    var id: String {
        switch requestId {
        case .string(let s): return s
        case .int(let i): return String(i)
        }
    }
    let requestId: JSONRPCID
    let questions: [UserInputQuestion]
    var isSubmitted: Bool = false
}

// MARK: - Proposed Plan Card

struct ProposedPlanCard: View {
    let content: String
    let isStreaming: Bool
    let onImplement: () -> Void
    let onContinuePlanning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.footnote.weight(.semibold))
                Text("Proposed Plan")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.blue)

            // Plan content
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(content: content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Planning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons (shown when not streaming)
            if !isStreaming && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 10) {
                    Button(action: onImplement) {
                        HStack(spacing: 4) {
                            Image(systemName: "hammer")
                                .font(.caption.weight(.semibold))
                            Text("Implement this plan")
                                .font(.footnote.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button(action: onContinuePlanning) {
                        Text("Continue planning")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray5))
                            .foregroundStyle(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - User Input Questions Sheet

/// A sheet that presents plan-mode questions one at a time with swipe navigation.
/// Automatically dismisses after the user submits their answers.
struct UserInputQuestionsSheet: View {
    let request: PendingUserInputRequest
    let onSubmit: (JSONRPCID, [String: [String]]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var otherTexts: [String: String] = [:]

    private var questions: [UserInputQuestion] { request.questions }
    private var isLastPage: Bool { currentPage >= questions.count - 1 }
    private var hasAnySelection: Bool {
        for question in questions {
            if let selected = selections[question.id], !selected.isEmpty { return true }
            if let text = otherTexts[question.id], !text.isEmpty { return true }
        }
        return false
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Page indicator
                if questions.count > 1 {
                    pageIndicator
                        .padding(.top, 8)
                }

                // Swipeable question pages
                TabView(selection: $currentPage) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        questionPage(for: question)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: currentPage)

                // Bottom bar with navigation and submit
                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .navigationTitle("Plan Mode Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        // Submit empty answers to unblock the server
                        onSubmit(request.requestId, [:])
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<questions.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.blue : Color(.systemGray4))
                    .frame(width: 7, height: 7)
                    .onTapGesture { currentPage = index }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Question Page

    private func questionPage(for question: UserInputQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header badge
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Question text
                Text(question.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if question.multiSelect {
                    Text("Select all that apply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Options
                VStack(spacing: 8) {
                    ForEach(question.options) { option in
                        if option.isOther {
                            otherInputRow(for: question, option: option)
                        } else {
                            optionRow(for: question, option: option)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 80) // Space for bottom bar
        }
    }

    // MARK: - Option Row

    private func optionRow(for question: UserInputQuestion, option: UserInputOption) -> some View {
        let isSelected = selections[question.id]?.contains(option.label) ?? false

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                var current = selections[question.id] ?? []
                if question.multiSelect {
                    if current.contains(option.label) {
                        current.remove(option.label)
                    } else {
                        current.insert(option.label)
                    }
                } else {
                    current = [option.label]
                }
                selections[question.id] = current
            }
        } label: {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected
                    ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color(.systemGray4).opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Other Input Row

    private func otherInputRow(for question: UserInputQuestion, option: UserInputOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(option.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if option.isSecret {
                SecureField("Enter value...", text: Binding(
                    get: { otherTexts[question.id] ?? "" },
                    set: { otherTexts[question.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                TextField("Type your answer...", text: Binding(
                    get: { otherTexts[question.id] ?? "" },
                    set: { otherTexts[question.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Previous button
            if currentPage > 0 {
                Button {
                    withAnimation { currentPage -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                        Text("Previous")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if isLastPage || questions.count == 1 {
                // Submit button
                Button(action: submitAnswers) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                        Text("Submit")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(hasAnySelection ? Color.blue : Color.blue.opacity(0.4))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                // Next button
                Button {
                    withAnimation { currentPage += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                            .font(.footnote.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Submit

    private func submitAnswers() {
        var answers: [String: [String]] = [:]
        for question in questions {
            var selected = Array(selections[question.id] ?? [])
            if let otherText = otherTexts[question.id], !otherText.isEmpty {
                selected.append(otherText)
            }
            if !selected.isEmpty {
                answers[question.id] = selected
            }
        }
        onSubmit(request.requestId, answers)
        dismiss()
    }
}
