# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SaveClarifyingAnswer do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?", "Should it be flagged?" ]) }
  let(:session) { create(:chat_session, account:, created_by: user, project:, clarifying_question_issue: issue) }

  # @spec QUESTION-EXPLORATION-002 @spec QUESTION-EXPLORATION-013
  it "records a draft answer without posting to GitHub or clearing needs input" do
    result = described_class.new(user:, session:).call(
      position: 1,
      answer: "Keep the user on the current page.",
      evidence_context: "The operator's comment on the error-state diagram.",
      confirmed: true
    )

    expect(result).to include(posted: false, position: 1, question: "What should happen?")
    expect(issue.reload).to have_attributes(paid_state: "needs_input", needs_input_questions: [ "What should happen?", "Should it be flagged?" ])
    expect(issue.clarifying_question_progresses.find_by(position: 1)).to have_attributes(
      answer: "Keep the user on the current page.",
      evidence_context: "The operator's comment on the error-state diagram."
    )
  end

  # @spec QUESTION-EXPLORATION-018
  it "records a draft against the focused issue of a feature conversation" do
    feature = create(:feature_intent, project:)
    create(:feature_intent_issue, feature_intent: feature, issue:)
    focused = create(:issue, :needs_input, project:, needs_input_questions: [ "Which storage backend?" ])
    create(:feature_intent_issue, feature_intent: feature, issue: focused)
    session.update!(
      feature_intent: feature,
      metadata: {
        "clarifying_questions" => [ "Which storage backend?" ],
        "exploration_focus" => { "issue_id" => focused.id, "questions" => [ "Which storage backend?" ] }
      }
    )

    result = described_class.new(user:, session:).call(
      position: 1, answer: "Use the app database.", confirmed: true
    )

    expect(result).to include(posted: false, question: "Which storage backend?")
    expect(focused.clarifying_question_progresses.find_by(position: 1)).to have_attributes(
      answer: "Use the app database."
    )
  end

  it "requires confirmation before recording intent" do
    expect {
      described_class.new(user:, session:).call(position: 1, answer: "Draft", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end
end
