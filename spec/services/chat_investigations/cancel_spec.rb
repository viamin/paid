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
end
