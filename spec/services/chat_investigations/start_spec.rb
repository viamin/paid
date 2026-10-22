# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::Start do
  # @spec QUESTION-EXPLORATION-010
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:actor) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, project:, created_by: actor, clarifying_question_issue: issue) }
  let(:issue) { create(:issue, project:) }
  let(:question) do
    create(:clarifying_question_progress, account:, project:, issue:, chat_session: session, position: 1)
  end

  it "reserves shared hard-stop budget atomically before queueing research" do
    create(:cost_budget, :hard_stop, :daily, project:, limit_cents: 100,
      current_usage_cents: 30, period_started_at: Time.current.beginning_of_day)

    result = described_class.call(question:, actor:, kind: "research", prompt: "Compare the options", estimated_cost_cents: 70)

    expect(result).to be_queued
    expect(result.investigation).to have_attributes(status: "queued", reserved_cost_cents: 70)
    expect(ChatInvestigations::RunJob).to have_been_enqueued.with(result.investigation.id)
  end

  it "preserves the question and asks for authorization when a reservation would exceed budget" do
    create(:cost_budget, :hard_stop, :daily, project:, limit_cents: 100,
      current_usage_cents: 60, period_started_at: Time.current.beginning_of_day)

    result = described_class.call(question:, actor:, kind: "research", prompt: "Compare the options", estimated_cost_cents: 50)

    expect(result).to be_awaiting_authorization
    expect(result.investigation).to have_attributes(status: "awaiting_authorization", reserved_cost_cents: 0)
    expect(question.reload).to be_present
  end

  it "counts an in-flight reservation before admitting another investigation" do
    create(:cost_budget, :hard_stop, :daily, project:, limit_cents: 100,
      current_usage_cents: 0, period_started_at: Time.current.beginning_of_day)

    first = described_class.call(question:, actor:, kind: "research", prompt: "First", estimated_cost_cents: 60)
    second = described_class.call(question:, actor:, kind: "research", prompt: "Second", estimated_cost_cents: 50)

    expect(first).to be_queued
    expect(second).to be_awaiting_authorization
  end

  it "requires authorization when the maximum investigation cost exceeds a per-run hard stop" do
    create(:cost_budget, :hard_stop, :per_run, project:, limit_cents: 40)

    result = described_class.call(question:, actor:, kind: "research", prompt: "Compare the options", estimated_cost_cents: 50)

    expect(result).to be_awaiting_authorization
    expect(result.investigation.reserved_cost_cents).to eq(0)
  end
end
