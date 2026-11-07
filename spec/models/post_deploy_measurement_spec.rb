# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-004
RSpec.describe PostDeployMeasurement do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }

  it "validates tenant coherence of project and issue" do
    other_project = create(:project, account: account)
    measurement = build(:post_deploy_measurement, account: account, project: other_project, issue: issue)

    expect(measurement).not_to be_valid
    expect(measurement.errors[:issue]).to include("must belong to the project")
  end

  it "rejects a project outside its account" do
    other_account = create(:account)
    other_project = create(:project, account: other_account)
    measurement = build(:post_deploy_measurement, account: account, project: other_project,
      issue: create(:issue, project: other_project))

    expect(measurement).not_to be_valid
  end

  it "enforces the idempotency key across duplicate rows" do
    attrs = { account: account, project: project, issue: issue, check_key: "planning_hold_notifications_actionable",
              check_version: 1, deployed_revision: "", criterion: "criterion" }
    described_class.create!(attrs)

    expect { described_class.create!(attrs) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "status helpers" do
    it "classifies terminal and retry-eligible states" do
      pending_row = create(:post_deploy_measurement, issue: issue, project: project, status: "pending")
      unknown_row = create(:post_deploy_measurement, issue: issue, project: project, status: "unknown", attempts: 1,
        deployed_revision: "pr-1@2026-11-07T00:00:00Z")
      exhausted_row = create(:post_deploy_measurement, issue: issue, project: project, status: "unknown", attempts: 3,
        deployed_revision: "pr-2@2026-11-07T00:00:00Z")

      expect(pending_row).not_to be_terminal
      expect(pending_row).to be_retryable
      expect(unknown_row).to be_retryable
      expect(exhausted_row).not_to be_retryable
      expect(issue.post_deploy_measurements.actionable).to contain_exactly(pending_row, unknown_row)
    end

    it "treats evidence as current only for its exact revision and check version" do
      measurement = create(:post_deploy_measurement, issue: issue, project: project, status: "passed",
        deployed_revision: "pr-7@2026-11-07T00:00:00Z", check_version: 1)

      expect(measurement).to be_current_for(target_revision: "pr-7@2026-11-07T00:00:00Z", check_version: 1)
      expect(measurement).not_to be_current_for(target_revision: "pr-7@2026-11-08T00:00:00Z", check_version: 1)
      expect(measurement).not_to be_current_for(target_revision: "pr-7@2026-11-07T00:00:00Z", check_version: 2)
    end
  end
end
