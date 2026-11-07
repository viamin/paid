# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-003
RSpec.describe TrustedMeasurements::RunCheckJob do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :closed, project:, github_number: 4812) }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  it "runs the named check for the project and persists the attempt" do
    described_class.new.perform(
      project.id, check_key: "agent_planning_hold_reconciliation_closed_count",
      external_issue_number: issue.github_number, criterion_key: "closed_planning_hold_notifications_cleared"
    )

    attempt = TrustedMeasurementAttempt.last
    expect(attempt).to have_attributes(project_id: project.id, status: "succeeded", deployed_revision: "rev-1")
  end

  it "establishes tenant context for the project's own account while running" do
    observed_account_id = nil
    allow(TrustedMeasurements::RunCheck).to receive(:call).and_wrap_original do |method, **kwargs|
      observed_account_id = Current.account&.id
      method.call(**kwargs)
    end

    described_class.perform_now(
      project.id, check_key: "agent_planning_hold_reconciliation_closed_count",
      external_issue_number: issue.github_number, criterion_key: "closed_planning_hold_notifications_cleared"
    )

    expect(observed_account_id).to eq(project.account_id)
  end
end
