# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::PreflightCheck do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  before { create(:user_setting, user: user) }

  describe ".call" do
    context "with a healthy subscription runner" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "passes" do
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: true, reason: nil, runner_id: runner.id)
      end
    end

    context "with a healthy API-key runner" do
      let(:provider_api_key) { create(:provider_api_key, user: user) }
      let(:runner) { create(:runner, :api_key, user: user, runner_key: "claude", provider_api_key: provider_api_key) }

      it "passes" do
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: true, reason: nil, runner_id: runner.id)
      end
    end

    context "when runner is nil" do
      it "fails with runner_not_found" do
        result = described_class.call(runner: nil, user: user)
        expect(result).to have_attributes(pass?: false, reason: "runner_not_found", runner_id: nil)
      end
    end

    context "when runner is discarded" do
      let(:runner) { create(:runner, user: user, runner_key: "cursor", auth_type: "subscription") }

      it "fails with runner_discarded" do
        runner.discard
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: false, reason: "runner_discarded")
      end
    end

    context "when runner is disabled for agent runs" do
      let(:runner) do
        user.runners.kept_only.find_by(runner_key: "claude", auth_type: "subscription")
      end

      it "fails with runner_disabled" do
        runner.update_columns(enabled_for_agent_runs: false)
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: false, reason: "runner_disabled")
      end
    end

    context "when execution is disabled for the runner" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      # @spec EXEC-DISABLE-003
      it "fails with execution_disabled" do
        create(:execution_control, :runner_scope, :enabled, runner: runner)

        result = described_class.call(runner: runner, user: user)

        expect(result).to have_attributes(pass?: false, reason: "execution_disabled")
      end
    end

    # @spec RUNNER-SCHED-005
    context "when runner is blocked by a time-window restriction" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "fails with time_window_blocked when inside a block-mode window" do
        runner.update_columns(time_restrictions: {
          "mode" => "block", "timezone" => "UTC",
          "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
        })

        travel_to Time.utc(2026, 1, 1, 2, 0) do
          result = described_class.call(runner: runner, user: user)
          expect(result).to have_attributes(pass?: false, reason: "time_window_blocked", runner_id: runner.id)
        end
      end

      it "passes when outside every block-mode window" do
        runner.update_columns(time_restrictions: {
          "mode" => "block", "timezone" => "UTC",
          "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
        })

        travel_to Time.utc(2026, 1, 1, 5, 0) do
          result = described_class.call(runner: runner, user: user)
          expect(result).to have_attributes(pass?: true)
        end
      end

      it "passes for a deprioritize-mode runner even inside a window" do
        runner.update_columns(time_restrictions: {
          "mode" => "deprioritize", "timezone" => "UTC",
          "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
        })

        travel_to Time.utc(2026, 1, 1, 2, 0) do
          result = described_class.call(runner: runner, user: user)
          expect(result).to have_attributes(pass?: true)
        end
      end
    end

    context "with an API-key runner missing its secret" do
      let(:provider_api_key) { create(:provider_api_key, user: user) }
      let(:runner) { create(:runner, user: user, runner_key: "cursor", auth_type: "api_key", provider_api_key: provider_api_key) }

      before { allow(runner).to receive(:effective_api_secret).and_return(nil) }

      it "fails with missing_api_key" do
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: false, reason: "missing_api_key")
      end
    end

    context "when circuit breaker is open" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "fails with circuit_open" do
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key)
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: false, reason: "circuit_open")
      end
    end

    context "when runner is rate limited" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "fails with rate_limited" do
        create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: false, reason: "rate_limited")
      end
    end

    context "when circuit breaker transitions from open to half_open" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "passes when recovery timeout has elapsed" do
        create(:runner_state, :circuit_open, user: user, runner_name: runner.state_key,
          circuit_opened_at: 10.minutes.ago)

        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: true)
      end
    end

    context "when no runner state exists" do
      let(:runner) { user.runners.find_or_create_by!(runner_key: "claude", auth_type: "subscription") }

      it "passes (no failures recorded)" do
        result = described_class.call(runner: runner, user: user)
        expect(result).to have_attributes(pass?: true)
      end
    end

    describe "REASONS constant" do
      it "is a frozen array of strings" do
        expect(described_class::REASONS).to be_frozen
        expect(described_class::REASONS).to all(be_a(String))
      end

      it "raises ArgumentError when an unknown reason is passed to failure" do
        service = described_class.new(runner: nil, user: user)
        expect { service.send(:failure, "not_a_real_reason") }
          .to raise_error(ArgumentError, /unknown preflight reason/)
      end
    end
  end
end
