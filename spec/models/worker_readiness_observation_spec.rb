# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-005
RSpec.describe WorkerReadinessObservation, type: :model do
  let(:booted_at) { Time.utc(2026, 11, 22, 6, 0, 0) }

  def record(role, pid: 4242, ready_at: booted_at, revision: "revision-1",
    deployment_revision: "revision-1", heartbeat_at: booted_at + 30, environment: Rails.env)
    described_class.record!(role:, pid:, ready_at:, revision:, deployment_revision:, heartbeat_at:, environment:)
  end

  it "publishes and reads back a role's typed readiness identity" do
    record("poll")

    observation = described_class.for_role("poll", environment: Rails.env).sole

    expect(observation).to have_attributes(pid: 4242, revision: "revision-1", environment: Rails.env,
      deployment_revision: "revision-1", ready_at: booted_at, heartbeat_at: booted_at + 30)
  end

  it "keeps overlapping role instances distinct during a rolling restart" do
    record("agent", pid: 111, ready_at: booted_at, revision: "old-revision",
      deployment_revision: "old-deployment", heartbeat_at: booted_at + 1)
    record("agent", pid: 222, ready_at: booted_at + 10.minutes, revision: "revision-1",
      heartbeat_at: booted_at + 10.minutes + 30)

    expect(described_class.count).to eq(2)
    expect(described_class.for_role("agent", environment: Rails.env).pluck(:pid)).to contain_exactly(111, 222)
  end

  it "keeps the poll and agent roles independent" do
    record("poll", pid: 101)
    record("agent", pid: 102)

    expect(described_class.for_role("poll", environment: Rails.env).sole.pid).to eq(101)
    expect(described_class.for_role("agent", environment: Rails.env).sole.pid).to eq(102)
  end

  it "stores a null revision when the worker could not determine one" do
    record("poll", revision: nil)

    expect(described_class.for_role("poll", environment: Rails.env).sole).to have_attributes(revision: nil)
  end

  it "rejects roles outside the fixed Temporal pair and malformed identities" do
    expect { record("jobs") }.to raise_error(ArgumentError, /unsupported Temporal worker role/)
    expect { record("poll", pid: 0) }.to raise_error(ArgumentError, /worker pid must be positive/)
    expect do
      described_class.for_role("sidekiq", environment: Rails.env)
    end.to raise_error(ArgumentError, /unsupported Temporal worker role/)
  end

  it "keeps identical worker boots distinct across publishing environments" do
    record("poll", environment: "production")
    record("poll", environment: "staging")

    expect(described_class.count).to eq(2)
    expect(described_class.for_role("poll", environment: "production").sole.environment).to eq("production")
  end

  it "keeps ActiveRecord writes unusable for unsupported roles, environments, or PIDs" do
    observation = described_class.new(role: "jobs", pid: 4242, ready_at: booted_at,
      heartbeat_at: booted_at)
    expect(observation).not_to be_valid

    observation = described_class.new(role: "poll", environment: Rails.env, pid: 0, ready_at: booted_at,
      heartbeat_at: booted_at)
    expect(observation).not_to be_valid

    observation = described_class.new(role: "poll", pid: 4242, ready_at: booted_at,
      heartbeat_at: booted_at)
    expect(observation).not_to be_valid
  end
end
