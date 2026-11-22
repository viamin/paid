# frozen_string_literal: true

require "rails_helper"
require "paid/worker_readiness"

# @spec TRUSTED-MEASUREMENTS-008
RSpec.describe TrustedMeasurements::Checks::WorkerAdoption do
  let(:project) { create(:project) }
  let(:now) { Time.utc(2026, 11, 22, 7, 0, 58) }

  before do
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return("revision-1")
  end

  def snapshot(role, revision: "revision-1", ready_at: now - 1.minute, modified_at: ready_at, pid: 100)
    Paid::WorkerReadiness::Snapshot.new(role:, pid:, ready_at:, revision:, modified_at:, error: nil)
  end

  def collect(snapshots, alive: true)
    readiness = Object.new
    readiness.define_singleton_method(:temporal_snapshot) { |role| snapshots.fetch(role) }
    checker = described_class.new(
      project: project,
      readiness: readiness,
      clock: -> { Time.utc(2026, 11, 22, 7, 0, 58) },
      process_alive: ->(_pid) { alive }
    )
    checker.call
  end

  it "records both actual worker identities when they are ready, current, and fresh" do
    result = collect({ "poll" => snapshot("poll", pid: 101), "agent" => snapshot("agent", pid: 102) })

    expect(result).to be_passing
    expect(result.workers).to include(
      "poll" => include("pid" => 101, "revision" => "revision-1", "status" => "observed"),
      "agent" => include("pid" => 102, "revision" => "revision-1", "status" => "observed")
    )
    expect(result.project_scope).to eq("project:#{project.id}:#{project.full_name}")
  end

  it "keeps missing, stale, and revision-mismatched worker readiness unknown" do
    missing = snapshot("poll").with(error: "missing", pid: nil, ready_at: nil, revision: nil, modified_at: nil)
    expect(collect({ "poll" => missing, "agent" => snapshot("agent") })).to have_attributes(
      failure_reason: "missing_poll_readiness"
    )

    expect(collect({ "poll" => snapshot("poll", ready_at: now - 6.minutes), "agent" => snapshot("agent") })).to have_attributes(
      failure_reason: "stale_poll_readiness"
    )

    expect(collect({ "poll" => snapshot("poll", revision: "old-revision"), "agent" => snapshot("agent") })).to have_attributes(
      failure_reason: "poll_revision_mismatch"
    )
  end

  it "rejects a dead PID or readiness identity that predates the published boot timestamp" do
    expect(collect({ "poll" => snapshot("poll"), "agent" => snapshot("agent") }, alive: false)).to have_attributes(
      failure_reason: "poll_pid_not_alive"
    )

    restarted = snapshot("poll", modified_at: now - 3.minutes)
    expect(collect({ "poll" => restarted, "agent" => snapshot("agent") })).to have_attributes(
      failure_reason: "poll_readiness_identity_mismatch"
    )
  end
end
