# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::StartChatInvestigation do
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }
  let(:session) { create(:chat_session, account:, created_by: user, project:, clarifying_question_issue: issue) }

  before do
    FeatureFlags.enable!(:question_exploration, project:)
    ClarifyingQuestions::SaveProgress.call(chat_session: session, position: 1, answer: "Investigate first", actor: user)
  end

  it "starts confirmed question-scoped research through the same authorized chat tool boundary" do
    result = described_class.new(user:, session:).call(
      position: 1, kind: "research", prompt: "Compare the options", estimated_cost_cents: 5, confirmed: true
    )

    expect(result).to include(status: "queued", question_position: 1, authorization_required: false)
  end

  it "does not start without a human confirmation" do
    expect {
      described_class.new(user:, session:).call(position: 1, kind: "research", prompt: "Compare", confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "does not expose investigation dispatch while the project rollout is disabled" do
    FeatureFlags.disable!(:question_exploration, project:)

    expect(described_class).not_to be_available_for_chat(user:, session:)
  end
end
