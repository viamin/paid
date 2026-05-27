# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::RunnerHealth do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  def create_runner_attempts(project:, attempts:)
    create(:agent_run, :failed, project: project, runners_attempted: attempts)
  end

  def expect_runner_health_summary(stats, available_runner:, rate_limited_runner:)
    expect(stats).to include(
      total: 2,
      available: 1,
      rate_limited: 1,
      circuit_open: 0,
      recovering: 0,
      healthy: false
    )
    expect(stats[:runners].map(&:runner)).to eq([ rate_limited_runner.display_name, available_runner.display_name ])
    expect(stats[:runners].map(&:status)).to eq([ :rate_limited, :available ])
    expect(stats[:runners].map(&:attempt_count)).to eq([ 1, 1 ])
  end

  describe ".call" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account, name: "Operator One", email: "operator@example.com") }
    let(:default_runner) { user.runners.find_by!(runner_key: Runner.default_runner_key, auth_type: "subscription") }
    let(:secondary_runner_key) { (RunnerSupport.container_executable_runner_keys - [ default_runner.runner_key ]).first || "cursor" }
    let(:project) do
      create(
        :project,
        account: account,
        created_by: user,
        github_token: create(:github_token, account: account, created_by: user)
      )
    end

    it "returns configured runner health for the account" do
      available_runner = default_runner
      rate_limited_runner = create(:runner, user: user, runner_key: secondary_runner_key, auth_type: "subscription")
      create(:runner_state, user: user, runner_name: rate_limited_runner.state_key, rate_limited_until: 10.minutes.from_now)
      create_runner_attempts(
        project: project,
        attempts: [
          { "runner" => rate_limited_runner.state_key, "success" => false },
          { "runner" => available_runner.state_key, "success" => true }
        ]
      )

      stats = described_class.call(account: account)

      expect_runner_health_summary(stats, available_runner: available_runner, rate_limited_runner: rate_limited_runner)
    end

    it "filters runners to the current account" do
      default_runner

      other_user = create(:user)
      create(:runner, user: other_user, runner_key: secondary_runner_key)

      stats = described_class.call(account: account)

      expect(stats[:total]).to eq(1)
      expect(stats[:runners].map(&:owner_email)).to eq([ user.email ])
    end

    it "uses each runner owner's configured circuit breaker timeout when checking recovery" do
      runner = default_runner
      create(:user_setting, user: user, circuit_breaker_timeout_seconds: 30)
      create(
        :runner_state,
        :circuit_open,
        user: user,
        runner_name: runner.state_key,
        circuit_opened_at: 31.seconds.ago
      )

      stats = described_class.call(account: account)

      expect(stats[:circuit_open]).to eq(0)
      expect(stats[:recovering]).to eq(1)
      expect(stats[:runners].map(&:status)).to eq([ :recovering ])
    end

    it "keeps the attempt count at least as high as the current failure count" do
      create(:runner_state, user: user, runner_name: default_runner.state_key, failure_count: 3)

      stats = described_class.call(account: account)

      expect(stats[:runners].first.failure_count).to eq(3)
      expect(stats[:runners].first.attempt_count).to eq(3)
    end

    it "counts recent attempts from older runs using the attempt timestamp" do
      create(
        :agent_run,
        :failed,
        project: project,
        created_at: 10.days.ago,
        runners_attempted: [
          {
            "runner" => default_runner.state_key,
            "success" => false,
            "attempted_at" => 1.day.ago.iso8601
          }
        ]
      )

      stats = described_class.call(account: account)

      expect(stats[:runners].first.attempt_count).to eq(1)
    end
  end
end
