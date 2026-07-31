# frozen_string_literal: true

require "rails_helper"

# @spec RUNNER-SCHED-008, RUNNER-SCHED-009
RSpec.describe Runners::TimeWindowPark do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:agent_run) { create(:agent_run, project: project, status: "queued") }

  def block_config(start_h, end_h)
    { "mode" => "block", "timezone" => "UTC",
      "windows" => [ { "start_hour" => start_h, "end_hour" => end_h } ] }
  end

  # Creates or updates a runner with time restrictions, bypassing model
  # validations to avoid fighting the "last runner" / "default runner"
  # constraints that are irrelevant to this service's logic.
  def add_runner(key, restrictions)
    runner = user.runners.kept_only.find_or_create_by!(runner_key: key, auth_type: "subscription")
    runner.update_columns(time_restrictions: restrictions, enabled_for_agent_runs: true)
    runner
  end

  before do
    # Disable existing auto-created runners so the test controls which are
    # eligible. Uses update_columns to bypass the "last runner" validation.
    user.runners.kept_only.each do |r|
      r.update_columns(enabled_for_agent_runs: false)
    end
  end

  it "returns nil when no eligible runners exist" do
    expect(described_class.call(agent_run, now: Time.utc(2026, 1, 1, 2, 0))).to be_nil
  end

  # @spec RUNNER-SCHED-009
  it "returns nil when at least one runner is not blocked" do
    add_runner("cursor", block_config(1, 4))
    add_runner("gemini", nil)

    expect(described_class.call(agent_run, now: Time.utc(2026, 1, 1, 2, 0))).to be_nil
  end

  # @spec RUNNER-SCHED-008
  it "returns the earliest available time when all runners are blocked" do
    add_runner("cursor", block_config(1, 4))
    add_runner("gemini", block_config(1, 6))

    result = described_class.call(agent_run, now: Time.utc(2026, 1, 1, 2, 0))
    expect(result).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
  end

  it "ignores deprioritize-mode runners for parking decisions" do
    add_runner("cursor", block_config(1, 4))
    add_runner("gemini", { "mode" => "deprioritize", "timezone" => "UTC",
      "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ] })

    expect(described_class.call(agent_run, now: Time.utc(2026, 1, 1, 2, 0))).to be_nil
  end

  it "respects exclude_runner_ids" do
    cursor = add_runner("cursor", block_config(1, 4))
    add_runner("gemini", block_config(1, 4))

    result = described_class.call(agent_run, exclude_runner_ids: [ cursor.id ],
      now: Time.utc(2026, 1, 1, 2, 0))
    expect(result).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
  end
end
