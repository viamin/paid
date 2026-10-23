# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunAcceptanceAuditActivity do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:run) { create(:agent_run, :queued, project:, issue:, goal: "analyze_issue") }

  # @spec PARTIAL-CLOSEOUT-027
  it "persists a refreshed report without changing issue state" do
    issue.update!(paid_state: "in_progress")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).with(agent_run: run).and_return({ "gaps" => [] })

    described_class.new.execute(agent_run_id: run.id)

    expect(run.reload.reconciliation.dig("assessment", "source_revision")).to be_present
    expect(run.reload.status).to eq("completed")
    expect(issue.reload.paid_state).to eq("in_progress")
  end
end
