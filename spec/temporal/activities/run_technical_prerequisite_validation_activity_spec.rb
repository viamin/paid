# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RunTechnicalPrerequisiteValidationActivity do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:) }
  let(:run) { create(:agent_run, :queued, project:, issue:, goal: "analyze_issue") }

  # @spec PARTIAL-CLOSEOUT-030
  it "persists the validation outcome on the source run and completes it" do
    result = PartialCloseouts::PrerequisiteValidation::Result.new(status: "unavailable", evidence: {})
    allow(PartialCloseouts::PrerequisiteValidation).to receive(:call).with(agent_run: run).and_return(result)

    response = described_class.new.execute(agent_run_id: run.id)

    expect(response).to include(technical_prerequisite_validation: "unavailable")
    expect(run.reload.status).to eq("completed")
  end
end
