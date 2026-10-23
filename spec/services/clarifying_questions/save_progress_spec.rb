# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::SaveProgress do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:user) { create(:user, :admin, account:) }
  let(:questions) { [ "Which behavior is expected?", "Should this use a flag?" ] }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: questions) }
  let(:chat_session) { create(:chat_session, account:, project:, created_by: user, clarifying_question_issue: issue) }

  # @spec QUESTION-EXPLORATION-002 @spec QUESTION-EXPLORATION-013
  it "persists one answer while leaving other questions unresolved" do
    progress = described_class.call(
      chat_session:,
      position: 1,
      answer: "Return the validation error inline.",
      evidence_context: "The operator rejected a redirect after reviewing the current form.",
      design_claim: "QUESTION-EXPLORATION-002",
      actor: user
    )

    expect(progress).to have_attributes(
      issue:,
      question: questions.first,
      answer: "Return the validation error inline.",
      evidence_context: "The operator rejected a redirect after reviewing the current form.",
      design_claim: "QUESTION-EXPLORATION-002",
      answered_by: user
    )
    expect(issue.clarifying_question_progresses.where(answer: nil)).to contain_exactly(
      have_attributes(position: 2, question: questions.second)
    )
  end

  # @spec QUESTION-EXPLORATION-013
  it "updates the same durable record when an answer is revised after the chat is archived" do
    described_class.call(chat_session:, position: 1, answer: "First answer", actor: user)
    ChatSessions::Archive.call(chat_session:)

    expect {
      described_class.call(chat_session:, position: 1, answer: "Revised answer", actor: user)
    }.not_to change(ClarifyingQuestionProgress, :count)

    expect(issue.clarifying_question_progresses.find_by(position: 1)).to have_attributes(
      answer: "Revised answer", answered_by: user
    )
  end

  # @spec QUESTION-EXPLORATION-013
  it "bounds evidence context when saving a draft answer" do
    progress = described_class.call(
      chat_session:, position: 1, answer: "Keep the user on the current page.", actor: user,
      evidence_context: "x" * (ClarifyingQuestionProgress::EVIDENCE_CONTEXT_MAX_CHARS + 1)
    )

    expect(progress.evidence_context).to eq("#{"x" * (ClarifyingQuestionProgress::EVIDENCE_CONTEXT_MAX_CHARS - 1)}…")
  end

  # @spec QUESTION-EXPLORATION-018
  it "records progress for the focused issue of a feature conversation" do
    feature = create(:feature_intent, project:)
    create(:feature_intent_issue, feature_intent: feature, issue:)
    focused = create(:issue, :needs_input, project:, needs_input_questions: [ "Which storage backend?" ])
    create(:feature_intent_issue, feature_intent: feature, issue: focused)
    feature_session = create(:chat_session, account:, project:, created_by: user,
      clarifying_question_issue: issue, feature_intent: feature,
      metadata: {
        "clarifying_questions" => [ "Which storage backend?" ],
        "exploration_focus" => { "issue_id" => focused.id, "questions" => [ "Which storage backend?" ] }
      })

    progress = described_class.call(
      chat_session: feature_session, position: 1, answer: "Use the app database.", actor: user
    )

    expect(progress).to have_attributes(
      issue: focused,
      question: "Which storage backend?",
      answer: "Use the app database.",
      chat_session: feature_session
    )
  end
end
