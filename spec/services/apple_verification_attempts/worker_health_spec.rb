# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-015
RSpec.describe AppleVerificationAttempts::WorkerHealth do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:profile) { create(:apple_worker_profile, account: account) }
  let(:clock) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  it "tracks consecutive failures and quarantines the profile once the threshold is crossed" do
    monitor = described_class.new(profile: profile, failure_threshold: 3, clock: clock)

    3.times do
      monitor.record(:failed)
    end

    profile.reload
    expect(profile.consecutive_health_failures).to eq(3)
    expect(profile.quarantined_at).to eq(clock)
    expect(profile.quarantine_reason).to include("consecutive_health_failures=3")
  end

  it "does not re-quarantine an already quarantined profile" do
    profile.update!(quarantined_at: clock - 1.day, quarantine_reason: "prior")

    described_class.new(profile: profile, failure_threshold: 3, clock: clock).record(:failed)

    expect(profile.reload.quarantined_at).to eq(clock - 1.day)
    expect(profile.quarantine_reason).to eq("prior")
  end

  it "finalizes active attempts when the profile enters quarantine" do
    attempt = running_attempt

    monitor = described_class.new(profile: profile, failure_threshold: 3, clock: clock)
    3.times { monitor.record(:failed) }

    expect(attempt.reload).to have_attributes(
      status: "unavailable",
      failure_classification: "worker_infrastructure",
      finished_at: clock
    )
    expect(attempt.container_retained_until).to be_present
  end

  it "clears the consecutive failure counter on a passing health check" do
    profile.update!(consecutive_health_failures: 2)

    described_class.new(profile: profile, clock: clock).record(:passed)

    expect(profile.reload.consecutive_health_failures).to eq(0)
  end

  it "records failed host readiness checks and quarantines active attempts" do
    attempt = running_attempt
    host = instance_double(AppleVerification::HostClient)
    lifecycle = AppleVerification::Lifecycle.new(host: host, token: "host-token")
    allow(host).to receive(:call).with(
      version: "v1", operation: "readiness", payload: {}, token: "host-token"
    ).and_raise(Timeout::Error)
    monitor = described_class.new(profile: profile, failure_threshold: 3, lifecycle:, clock: clock)

    3.times { monitor.call }

    expect(profile.reload).to be_quarantined
    expect(attempt.reload).to have_attributes(
      status: "unavailable",
      failure_classification: "worker_infrastructure"
    )
  end

  it "returns the profile to service only when an operator passes the isolation smoke test" do
    profile.update!(
      quarantined_at: clock - 1.hour,
      quarantine_reason: "three consecutive health failures",
      consecutive_health_failures: 3,
      last_health_failure_at: clock - 1.hour
    )

    operator = create(:user, account: account)
    smoke_test_result = stub_smoke_result(passed: true, operator: operator)

    described_class.new(profile: profile, clock: clock + 2.hours).return_to_service(smoke_test_result: smoke_test_result)

    profile.reload
    expect(profile.quarantined_at).to be_nil
    expect(profile.quarantine_reason).to be_nil
    expect(profile.consecutive_health_failures).to eq(0)
    expect(profile.returned_to_service_at).to eq(clock + 2.hours)
    expect(profile.returned_to_service_by_id).to eq(operator.id)
  end

  it "rejects a return_to_service call when the isolation smoke test has not passed" do
    profile.update!(quarantined_at: clock)

    expect {
      described_class.new(profile: profile, clock: clock).return_to_service(
        smoke_test_result: stub_smoke_result(passed: false, operator: nil)
      )
    }.to raise_error(ArgumentError, /smoke test/)
  end

  def stub_smoke_result(passed:, operator:)
    result = Object.new
    result.define_singleton_method(:passed?) { passed }
    result.define_singleton_method(:operator_id) { operator&.id }
    result
  end

  def running_attempt
    workflow = create(
      :apple_verification_workflow_revision,
      :approved,
      project: project,
      account: account,
      apple_worker_profile: profile
    )
    create(
      :apple_verification_attempt,
      project: project,
      account: account,
      apple_verification_workflow_revision: workflow,
      apple_worker_profile: profile,
      status: "running",
      started_at: clock - 1.minute,
      lifecycle_gate: workflow.lifecycle_gate
    )
  end
end
