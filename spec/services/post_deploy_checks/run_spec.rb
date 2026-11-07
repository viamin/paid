# frozen_string_literal: true

require "rails_helper"

# @spec POST-DEPLOY-CHECK-002 POST-DEPLOY-CHECK-003 POST-DEPLOY-CHECK-004
# @spec POST-DEPLOY-CHECK-005 POST-DEPLOY-CHECK-006B POST-DEPLOY-CHECK-011
RSpec.describe PostDeployChecks::Run do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:check_key) { PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount::KEY }

  def call(deployed_revision: "rev-1", source_issue: nil)
    described_class.call(check_key:, project:, deployed_revision:, source_issue:)
  end

  it "raises UnknownCheckError for a check key outside the allowlist, before touching the database" do
    expect do
      described_class.call(check_key: "DROP TABLE users", project:, deployed_revision: "rev-1")
    end.to raise_error(PostDeployChecks::UnknownCheckError)

    expect(PostDeployCheckRun.count).to eq(0)
  end

  it "runs the allowlisted check and persists a succeeded evidence row" do
    run = call

    expect(run).to have_attributes(status: "succeeded", check_key:, check_version: 1, deployed_revision: "rev-1")
    expect(run.result).to include("active_total" => 0, "active_with_closed_source" => 0)
    expect(run.executed_at).to be_present
  end

  it "records status unknown without executing the check when no deployed_revision is supplied" do
    run = call(deployed_revision: nil)

    expect(run).to have_attributes(status: "unknown")
    expect(run.failure_reason).to match(/deployed revision/i)
    expect(run.result).to eq({})
  end

  it "records status unknown without executing the check when the source issue is not deployed" do
    pull_request = create(:issue, :pull_request, project:)

    run = call(source_issue: pull_request)

    expect(run).to have_attributes(status: "unknown")
    expect(run.failure_reason).to match(/not marked deployed/i)
  end

  it "executes once the source issue is marked deployed" do
    pull_request = create(:issue, :pull_request, project:)
    pull_request.mark_deployed!

    run = call(source_issue: pull_request)

    expect(run).to have_attributes(status: "succeeded")
  end

  it "is idempotent: the same check/project/revision returns the existing row instead of re-running" do
    first = call

    expect(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).not_to receive(:call)
    second = call

    expect(second.id).to eq(first.id)
  end

  it "treats a new deployed_revision as a distinct attempt and supersedes the prior current evidence" do
    first = call(deployed_revision: "rev-1")

    second = call(deployed_revision: "rev-2")

    expect(first.reload.superseded_by_id).to eq(second.id)
    expect(PostDeployCheckRun.current).to contain_exactly(second)
  end

  it "does not supersede prior evidence when the new attempt fails" do
    first = call(deployed_revision: "rev-1")
    allow(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).to receive(:call).and_raise(StandardError, "boom")

    described_class.call(check_key:, project:, deployed_revision: "rev-2")

    expect(first.reload.superseded_by_id).to be_nil
    expect(PostDeployCheckRun.current).to include(first)
  end

  it "records a failed attempt and escalates immediately for a non-retryable error" do
    allow(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).to receive(:call).and_raise(NoMethodError, "boom")

    run = call

    expect(run).to have_attributes(status: "failed", failure_reason: "boom")
    expect(Notification.where(account:, source: "post_deploy_check_execution_failed", subject: project)).to exist
  end

  it "does not escalate a retryable infrastructure error before the persistent-failure threshold" do
    allow(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).to receive(:call)
      .and_raise(ActiveRecord::ConnectionTimeoutError, "timed out")

    call(deployed_revision: "rev-1")
    call(deployed_revision: "rev-2")

    expect(Notification.where(account:, source: "post_deploy_check_persistent_failure")).not_to exist
  end

  it "escalates a retryable infrastructure error once it persists across the threshold" do
    allow(PostDeployChecks::Checks::ClosedAgentPlanningHoldReconciliationCount).to receive(:call)
      .and_raise(ActiveRecord::ConnectionTimeoutError, "timed out")

    call(deployed_revision: "rev-1")
    call(deployed_revision: "rev-2")
    call(deployed_revision: "rev-3")

    expect(Notification.where(account:, source: "post_deploy_check_persistent_failure", subject: project)).to exist
  end

  it "raises AuthorizationError instead of trusting a zero-row read when no tenant context is established", :tenant_isolation do
    TenantContext.clear!

    expect { call }.to raise_error(PostDeployChecks::AuthorizationError)
    expect(PostDeployCheckRun.count).to eq(0)
  end

  it "runs successfully under an explicitly established tenant context", :tenant_isolation do
    TenantContext.apply!(account)

    run = call

    expect(run).to have_attributes(status: "succeeded")
  end
end
