# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-008
RSpec.describe TrustedMeasurements::Checks::WorkerAdoption do
  let(:project) { create(:project) }
  let(:now) { Time.utc(2026, 11, 22, 7, 0, 58) }

  before do
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return("revision-1")
  end

  def collect(at: now)
    described_class.new(project:, clock: -> { at }).call
  end

  # The writer path the worker roles themselves use: bin/temporal_worker
  # heartbeats through WorkerReadinessObservation.record!, and this collector
  # reads the same durable rows from wherever RunCheck executes.
  def record_role(role, pid:, ready_at:, heartbeat_at:, revision: "revision-1")
    WorkerReadinessObservation.record!(role:, pid:, ready_at:, revision:, heartbeat_at:)
  end

  # Production topology regression: config/deploy.yml runs the collector in
  # the job container while the worker roles publish from independent
  # worker_poll/worker_agent containers with no shared volume or PID
  # namespace. The database is the only shared channel, so evidence flows
  # exactly as it does in production — no readiness file or in-process
  # readiness double bridges the boundary.
  it "collects adoption evidence the owning worker roles recorded through the shared database" do
    expect(Process).not_to receive(:kill)
    record_role("poll", pid: 101, ready_at: now - 3.hours, heartbeat_at: now - 20.seconds)
    record_role("agent", pid: 102, ready_at: now - 2.hours, heartbeat_at: now - 45.seconds)

    result = collect

    expect(result).to be_passing
    expect(result.workers).to include(
      "poll" => include("pid" => 101, "revision" => "revision-1", "status" => "observed",
        "heartbeat_at" => (now - 20.seconds).iso8601),
      "agent" => include("pid" => 102, "revision" => "revision-1", "status" => "observed")
    )
    expect(result.project_scope).to eq("project:#{project.id}:#{project.full_name}")
    expect(result.environment).to eq(Rails.env.to_s)
  end

  it "keeps a healthy long-running worker current while its heartbeat stays fresh" do
    record_role("poll", pid: 101, ready_at: now - 3.days, heartbeat_at: now - 30.seconds)
    record_role("agent", pid: 102, ready_at: now - 9.days, heartbeat_at: now - 30.seconds)

    expect(collect).to be_passing
  end

  it "keeps missing, stale, and future-dated worker observations unknown" do
    record_role("agent", pid: 102, ready_at: now - 1.minute, heartbeat_at: now - 1.minute)

    expect(collect).to have_attributes(failure_reason: "missing_poll_readiness", unknown?: true)

    record_role("poll", pid: 101, ready_at: now - 1.hour, heartbeat_at: now - 6.minutes)
    expect(collect).to have_attributes(failure_reason: "stale_poll_readiness")

    record_role("poll", pid: 101, ready_at: now - 1.hour, heartbeat_at: now + 2.minutes)
    expect(collect).to have_attributes(failure_reason: "stale_poll_readiness")
  end

  it "keeps interrupted adoption unknown when a worker stops heartbeating" do
    record_role("poll", pid: 101, ready_at: now - 20.minutes, heartbeat_at: now - 20.minutes)
    record_role("agent", pid: 102, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds)

    expect(collect).to have_attributes(failure_reason: "stale_poll_readiness")
  end

  it "keeps revision-mismatched and unrevisoned workers unknown" do
    record_role("agent", pid: 102, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds)

    record_role("poll", pid: 101, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds, revision: "old-revision")
    expect(collect).to have_attributes(failure_reason: "poll_revision_mismatch")

    record_role("poll", pid: 101, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds, revision: nil)
    expect(collect).to have_attributes(failure_reason: "poll_revision_mismatch")
  end

  it "recovers once a restarted role adopts the current revision" do
    record_role("poll", pid: 101, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds, revision: "old-revision")
    record_role("agent", pid: 102, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds)
    expect(collect).to have_attributes(failure_reason: "poll_revision_mismatch")

    record_role("poll", pid: 900, ready_at: now - 10.seconds, heartbeat_at: now - 5.seconds)
    expect(collect).to be_passing
  end

  it "keeps corrupted or incoherent observations unknown" do
    record_role("agent", pid: 102, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds)
    record_role("poll", pid: 101, ready_at: now - 1.minute, heartbeat_at: now - 30.seconds)

    poll = WorkerReadinessObservation.for_role("poll")
    poll.update_column(:pid, 0)
    expect(collect).to have_attributes(failure_reason: "malformed_poll_readiness")

    poll.update_column(:pid, 101)
    poll.update_column(:heartbeat_at, now - 5.minutes)
    expect(collect).to have_attributes(failure_reason: "poll_readiness_identity_mismatch")
  end
end
