# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::Cancel do
  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-013
  it "cancels active work without changing the related question progress" do
    investigation = create(:chat_investigation, reserved_cost_cents: 10)
    question = investigation.clarifying_question_progress

    described_class.call(investigation:, actor: investigation.created_by)

    expect(investigation.reload).to have_attributes(status: "cancelled", reserved_cost_cents: 0, cancelled_at: be_present)
    expect(question.reload).to be_present
  end

  it "does not let a completion consume a reservation after cancellation" do
    investigation = create(:chat_investigation, status: "running", reserved_cost_cents: 10)
    budget = create(:cost_budget, :hard_stop, :daily, project: investigation.project, limit_cents: 100)

    described_class.call(investigation:, actor: investigation.created_by)
    ChatInvestigations::Run.call(investigation:)

    expect(investigation.reload).to have_attributes(status: "cancelled", reserved_cost_cents: 0)
    expect(budget.reload.current_usage_cents).to eq(0)
  end
end
