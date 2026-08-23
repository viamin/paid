# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::InfrastructureSpendGuard do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:runner) { user.runners.kept_only.find_by!(runner_key: "claude", auth_type: "subscription") }
  let(:agent_run) { create(:agent_run, :queued, project: project, runner: runner) }
  let(:impact) { instance_double(ExecutionControls::RunImpact, enable!: true, disable!: true) }

  before do
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:info)
    allow(ExecutionControls::RunImpact).to receive(:new).and_return(impact)
  end

  def spend_limits(global_daily: 0, project_hourly: 0)
    {
      global_infra_spend_daily_limit_cents: global_daily,
      global_infra_spend_hourly_limit_cents: 0,
      account_infra_spend_daily_limit_cents: 0,
      account_infra_spend_hourly_limit_cents: 0,
      project_infra_spend_daily_limit_cents: 0,
      project_infra_spend_hourly_limit_cents: project_hourly,
      runner_infra_spend_daily_limit_cents: 0,
      runner_infra_spend_hourly_limit_cents: 0
    }
  end

  def call_guard(now:)
    described_class.call(
      account: account,
      project: project,
      agent_run: agent_run,
      selected_host: "local",
      now: now
    )
  end

  # @spec INFRA-SPEND-005
  it "publishes and resolves project threshold notifications with audit events" do
    allow(Capacity::InfrastructureLimits).to receive(:current).and_return(spend_limits(project_hourly: 100))
    allow(Capacity::InfrastructureSpend).to receive(:spent_cents).and_return(90, 10)
    allow(Capacity::InfrastructureSpend).to receive(:projected_cents_for_host).and_return(20, 0)

    result = call_guard(now: Time.utc(2026, 8, 23, 12, 15, 0))

    expect(result[:allowed]).to be(false)
    expect(result[:reason]).to eq("project_infra_spend_hourly_limit_exceeded")

    notification = Notification.find_by(
      account: account,
      source: "infra_spend_threshold_project_hourly",
      subject: project
    )
    expect(notification).to be_present
    expect(notification).to be_active
    expect(ExecutionAuditEvent.by_event_name(described_class::EVENT_THRESHOLD_BREACHED).count).to eq(1)

    recovery_result = call_guard(now: Time.utc(2026, 8, 23, 12, 20, 0))

    expect(recovery_result).to eq(allowed: true)
    expect(notification.reload.resolved_at).to be_present
    expect(ExecutionAuditEvent.by_event_name(described_class::EVENT_THRESHOLD_RECOVERED).count).to eq(1)
  end

  # @spec INFRA-SPEND-004
  it "auto-enables and recovers the global daily execution control" do
    allow(Capacity::InfrastructureLimits).to receive(:current).and_return(spend_limits(global_daily: 100))
    allow(Capacity::InfrastructureSpend).to receive(:spent_cents).and_return(90, 10)
    allow(Capacity::InfrastructureSpend).to receive(:projected_cents_for_host).and_return(20)

    result = call_guard(now: Time.utc(2026, 8, 23, 12, 15, 0))

    expect(result[:allowed]).to be(false)
    control = ExecutionControl.find_by!(scope: "global")
    expect(control.enabled).to be(true)
    expect(control.mode).to eq("emergency")
    expect(control.metadata["source"]).to eq(described_class::AUTO_CONTROL_SOURCE)

    described_class.recover_global_daily_threshold!(now: Time.utc(2026, 8, 23, 13, 0, 0))

    expect(control.reload.enabled).to be(false)
    expect(control.metadata["recovered_at"]).to be_present
  end

  # @spec INFRA-SPEND-005
  it "previews a breach without publishing notifications, audit events, or execution control changes" do
    allow(Capacity::InfrastructureLimits).to receive(:current).and_return(spend_limits(project_hourly: 100))
    allow(Capacity::InfrastructureSpend).to receive_messages(spent_cents: 90, projected_cents_for_host: 20)

    result = described_class.preview(
      account: account,
      project: project,
      agent_run: agent_run,
      selected_host: "local",
      now: Time.utc(2026, 8, 23, 12, 15, 0)
    )

    expect(result[:allowed]).to be(false)
    expect(result[:reason]).to eq("project_infra_spend_hourly_limit_exceeded")
    expect(Notification.count).to eq(0)
    expect(ExecutionAuditEvent.by_event_name(described_class::EVENT_THRESHOLD_BREACHED).count).to eq(0)
    expect(ExecutionControl.find_by(scope: "global")).to be_nil
  end
end
