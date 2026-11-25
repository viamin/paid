# frozen_string_literal: true

require "rails_helper"
require "paid/worker_readiness"

# @spec TRUSTED-MEASUREMENTS-008 DEVELOPMENT-ENVIRONMENT-UPDATE-005
RSpec.describe Paid::WorkerReadiness::Heartbeat do
  let(:booted_at) { Time.utc(2026, 11, 22, 6, 0, 0) }
  let(:clock) { -> { booted_at } }
  let(:identity) do
    { pid: 4242, revision: "revision-1", deployment_revision: "deployment-1", environment: "production" }
  end
  let(:beats) { [] }
  let(:recorder) { ->(beat) { beats << beat } }

  it "publishes one beat per served role with the fixed boot identity" do
    described_class.new(roles: %w[poll agent], identity:, recorder:, interval: 30.0, clock:).publish

    expect(beats).to contain_exactly(
      { role: "poll", pid: 4242, ready_at: booted_at, revision: "revision-1", environment: "production",
        deployment_revision: "deployment-1", at: booted_at },
      { role: "agent", pid: 4242, ready_at: booted_at, revision: "revision-1", environment: "production",
        deployment_revision: "deployment-1", at: booted_at }
    )
  end

  it "keeps beating on interval until stopped, so a long-running worker stays fresh" do
    ticks = [ 0 ]
    heartbeat = described_class.new(roles: %w[poll agent], identity:, recorder:, interval: 30.0, clock:,
      sleeper: ->(_seconds) {
        ticks[0] += 1
        heartbeat.stop if ticks[0] >= 2
      })

    heartbeat.run

    expect(ticks[0]).to eq(2)
    expect(beats.size).to eq(4)
  end

  it "keeps looping when one beat cannot be recorded" do
    ticks = [ 0 ]
    attempts = [ 0 ]
    heartbeat = described_class.new(roles: %w[poll agent], identity:, interval: 30.0, clock:,
      recorder: lambda { |beat|
        if beat.fetch(:role) == "poll"
          attempts[0] += 1
          raise "db unavailable" if attempts[0] == 1
        end

        beats << beat
      },
      sleeper: ->(_seconds) {
        ticks[0] += 1
        heartbeat.stop if ticks[0] >= 2
      })

    expect { heartbeat.run }.to output(/Failed to record worker readiness heartbeat/).to_stderr
    expect(beats).to include(hash_including(role: "poll"))
    expect(beats.count { |beat| beat.fetch(:role) == "agent" }).to eq(2)
  end

  it "stops a running heartbeat without waiting out the interval" do
    heartbeat = described_class.start(roles: %w[poll agent], identity:, recorder:, interval: 3600.0, clock:)

    expect { Timeout.timeout(10) { heartbeat.stop } }.not_to raise_error
  end

  it "rejects a non-positive interval at construction" do
    expect do
      described_class.new(roles: %w[poll], identity:, recorder:, interval: 0, clock:)
    end.to raise_error(ArgumentError, /interval must be positive/)
  end
end
