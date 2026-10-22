# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::LatestVerificationSetupObservation do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:reasons) { [ "app_start_command_unavailable" ] }

  def record_observation(run, reason:, observed_at:, checkout_revision: "target-sha")
    run.update!(
      verification_result: {
        "status" => "failed",
        "reason" => reason,
        "readiness_observation" => {
          "reason" => reason,
          "agent_run_id" => run.id,
          "checkout_revision" => checkout_revision,
          "observed_at" => observed_at
        }.compact
      }
    )
  end

  # An older, long-running run can record its setup failure after a newer run
  # already recorded one; the observation time is what decides which evidence is
  # newest, not the run's creation time.
  # @spec PROJECT-READINESS-012
  it "returns the observation recorded last regardless of run creation order" do
    long_running = create(:agent_run, project:, issue:, status: "failed", created_at: 3.hours.ago)
    short_run = create(:agent_run, project:, issue:, status: "failed", created_at: 1.hour.ago)
    record_observation(short_run, reason: "app_start_command_unavailable", observed_at: 2.hours.ago.iso8601,
      checkout_revision: "stale-sha")
    record_observation(long_running, reason: "app_start_command_unavailable", observed_at: 1.minute.ago.iso8601,
      checkout_revision: "newest-sha")

    observation = described_class.call(project:, reasons:)

    expect(observation).to include("checkout_revision" => "newest-sha", "agent_run_id" => long_running.id)
  end

  # @spec PROJECT-READINESS-012
  it "ignores observations whose reason is not an active readiness gap" do
    run = create(:agent_run, project:, issue:, status: "failed", created_at: 3.hours.ago)
    record_observation(run, reason: "verification_configuration_invalid", observed_at: 1.minute.ago.iso8601,
      checkout_revision: "config-sha")

    expect(described_class.call(project:, reasons:)).to be_nil
  end

  # @spec PROJECT-READINESS-012
  it "prefers a recorded observation time over an undated one" do
    undated_run = create(:agent_run, project:, issue:, status: "failed", created_at: 3.hours.ago)
    dated_run = create(:agent_run, project:, issue:, status: "failed", created_at: 1.hour.ago)
    record_observation(undated_run, reason: "app_start_command_unavailable", observed_at: nil,
      checkout_revision: "undated-sha")
    record_observation(dated_run, reason: "app_start_command_unavailable", observed_at: 2.hours.ago.iso8601,
      checkout_revision: "dated-sha")

    expect(described_class.call(project:, reasons:)).to include("checkout_revision" => "dated-sha")
  end

  # @spec PROJECT-READINESS-012
  it "falls back to the newest run when no observation carries a recorded time" do
    older = create(:agent_run, project:, issue:, status: "failed", created_at: 3.hours.ago)
    newer = create(:agent_run, project:, issue:, status: "failed", created_at: 1.hour.ago)
    record_observation(older, reason: "app_start_command_unavailable", observed_at: nil, checkout_revision: "older-sha")
    record_observation(newer, reason: "app_start_command_unavailable", observed_at: nil, checkout_revision: "newer-sha")

    expect(described_class.call(project:, reasons:)).to include("checkout_revision" => "newer-sha")
  end

  # The observation is evidence for one run, so no run-count cutoff may hide a
  # later observation behind unrelated newer runs.
  # @spec PROJECT-READINESS-012
  it "finds a matching observation even when many newer runs exist" do
    matching = create(:agent_run, project:, issue:, status: "failed", created_at: 3.hours.ago)
    record_observation(matching, reason: "app_start_command_unavailable", observed_at: 3.hours.ago.iso8601,
      checkout_revision: "only-sha")
    25.times { create(:agent_run, project:, issue:, status: "failed", created_at: 1.minute.ago) }

    expect(described_class.call(project:, reasons:)).to include("checkout_revision" => "only-sha")
  end

  # @spec PROJECT-READINESS-012
  it "returns nil when no run recorded an observation" do
    create(:agent_run, project:, issue:, verification_result: { "status" => "passed" })

    expect(described_class.call(project:, reasons:)).to be_nil
  end

  # @spec PROJECT-READINESS-012
  it "returns nil without reading runs when no gap kind is active" do
    expect(project).not_to receive(:agent_runs)

    expect(described_class.call(project:, reasons: [])).to be_nil
  end
end
