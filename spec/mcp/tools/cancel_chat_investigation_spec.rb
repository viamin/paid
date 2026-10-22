# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::CancelChatInvestigation do
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, :needs_input, project:, needs_input_questions: [ "What should happen?" ]) }
  let(:session) { create(:chat_session, account:, created_by: user, project:, clarifying_question_issue: issue) }
  let(:investigation) { create(:chat_investigation, account:, project:, created_by: user, issue:, chat_session: session) }

  before { FeatureFlags.enable!(:question_exploration, project:) }

  it "cancels a confirmed investigation in the same authorized chat" do
    result = described_class.new(user:, session:).call(investigation_id: investigation.id, confirmed: true)

    expect(result).to include(investigation_id: investigation.id, status: "cancelled")
  end

  it "does not cancel without a human confirmation" do
    expect {
      described_class.new(user:, session:).call(investigation_id: investigation.id, confirmed: false)
    }.to raise_error(ArgumentError, /Confirmation required/)
  end

  it "does not expose cancellation while the exploration rollout is disabled" do
    FeatureFlags.disable!(:question_exploration, project:)

    expect(described_class).not_to be_available_for_chat(user:, session:)
  end
end
