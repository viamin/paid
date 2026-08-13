# frozen_string_literal: true

require "rails_helper"

RSpec.describe FreeModels::Rotation do
  let(:user) { create(:user) }
  let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
  let(:runner) do
    tier_model_ids.each do |tier, model_id|
      next if LlmModel.exists?(model_id: model_id)

      create(:llm_model, :free,
        model_id: model_id,
        tier: tier,
        capability_score: 5.0)
    end

    user.runners.create!(
      runner_key: Runner::OPENROUTER_FREE_RUNNER_KEY,
      auth_type: "api_key",
      provider_api_key: api_key,
      tier_model_ids: tier_model_ids
    )
  end

  def free_model(tier:, capability_score:, model_id: nil, below_quality_bar: false)
    attrs = {
      provider: "openrouter",
      tier: tier,
      pricing_tier: "free",
      capability_score: capability_score,
      active: true
    }
    attrs[:model_id] = model_id if model_id
    attrs[:metadata] = { "below_quality_bar" => true } if below_quality_bar
    create(:llm_model, **attrs)
  end

  describe ".call" do
    context "when the runner is not openrouter_free" do
      let(:runner) do
        existing = user.runners.kept_only.find_by(runner_key: "claude")
        existing || user.runners.create!(
          runner_key: "claude",
          auth_type: "subscription",
          tier_model_ids: {}
        )
      end
      let(:tier_model_ids) { {} }

      it "returns an exhausted result without rotating" do
        result = described_class.call(runner: runner)

        expect(result.exhausted?).to be true
        expect(result.rotated?).to be false
      end
    end

    context "with candidates in the current tier" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before do
        free_model(tier: "high", capability_score: 8.0, model_id: "high-other")
        free_model(tier: "high", capability_score: 6.0, model_id: "high-weak")
      end

      it "selects the next highest-capability model in the same tier" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.rotated?).to be true
        expect(result.model_id).to eq("high-other")
        expect(result.previous_model_id).to eq("high-current")
        expect(result.tier).to eq("high")
        expect(runner.reload.tier_model_ids["high"]).to eq("high-other")
      end
    end

    context "when the current tier is exhausted and lower tiers remain" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before do
        free_model(tier: "mid", capability_score: 5.5, model_id: "mid-other")
        free_model(tier: "mid", capability_score: 5.0, model_id: "mid-extra")
        free_model(tier: "high", capability_score: 9.0, model_id: "high-other")
        runner.user.runner_states.create!(runner_name: Runner::OPENROUTER_FREE_RUNNER_KEY,
          metadata: { RunnerState::RATE_LIMITED_MODELS_METADATA_KEY => {
            "high-current" => 5.minutes.from_now.iso8601,
            "high-other" => 5.minutes.from_now.iso8601
          } })
      end

      it "walks to the next tier down and selects the highest-capability candidate" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.rotated?).to be true
        expect(result.tier).to eq("mid")
        expect(result.model_id).to eq("mid-other")
        expect(runner.reload.tier_model_ids["high"]).to eq("high-current")
        expect(runner.tier_model_ids["mid"]).to eq("mid-other")
      end
    end

    context "when every tier is exhausted" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before do
        free_model(tier: "high", capability_score: 8.0, model_id: "high-other")
        free_model(tier: "mid", capability_score: 5.0, model_id: "mid-other")
        runner.user.runner_states.create!(runner_name: Runner::OPENROUTER_FREE_RUNNER_KEY,
          metadata: { RunnerState::RATE_LIMITED_MODELS_METADATA_KEY => {
            "high-current" => 5.minutes.from_now.iso8601,
            "high-other" => 5.minutes.from_now.iso8601,
            "mid-current" => 5.minutes.from_now.iso8601,
            "mid-other" => 5.minutes.from_now.iso8601,
            "low-current" => 5.minutes.from_now.iso8601
          } })
      end

      it "returns an exhausted result and does not change tier_model_ids" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.exhausted?).to be true
        expect(result.rotated?).to be false
        expect(runner.reload.tier_model_ids["high"]).to eq("high-current")
        expect(runner.tier_model_ids["mid"]).to eq("mid-current")
      end
    end

    context "with project-level model exclusions" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }
      let(:project) { create(:project, account: user.account, created_by: user,
        model_preferences: { "excluded_free_model_ids" => [ "high-disallowed" ] }) }

      before do
        free_model(tier: "high", capability_score: 8.0, model_id: "high-allowed")
        free_model(tier: "high", capability_score: 8.5, model_id: "high-disallowed")
      end

      it "skips project-excluded models" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, project: project, current_tier: "high")

        expect(result.rotated?).to be true
        expect(result.model_id).to eq("high-allowed")
      end
    end

    context "with below-quality-bar models" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before { free_model(tier: "high", capability_score: 8.0, model_id: "high-only", below_quality_bar: true) }

      it "skips below_quality_bar models by default" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.exhausted?).to be true
      end

      it "considers below_quality_bar models when opted in" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high", include_below_quality_bar: true)

        expect(result.rotated?).to be true
        expect(result.model_id).to eq("high-only")
      end
    end

    context "with inactive candidate models" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before do
        inactive = free_model(tier: "high", capability_score: 9.0, model_id: "high-inactive")
        free_model(tier: "high", capability_score: 6.0, model_id: "high-active")
        inactive.update!(active: false)
      end

      it "ignores inactive candidates" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.model_id).to eq("high-active")
      end
    end

    context "when runner state marks a model rate-limited" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before do
        free_model(tier: "high", capability_score: 9.0, model_id: "high-blocked")
        free_model(tier: "high", capability_score: 5.0, model_id: "high-available")
        runner.user.runner_states.create!(runner_name: Runner::OPENROUTER_FREE_RUNNER_KEY,
          metadata: { RunnerState::RATE_LIMITED_MODELS_METADATA_KEY => {
            "high-blocked" => 5.minutes.from_now.iso8601
          } })
      end

      it "skips the rate-limited candidate even if it has a higher capability score" do
        result = described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(result.model_id).to eq("high-available")
      end
    end

    describe "tier_model_ids recovery snapshot" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before { free_model(tier: "high", capability_score: 8.0, model_id: "high-other") }

      def runner_state
        user.runner_states.find_or_create_by!(runner_name: Runner::OPENROUTER_FREE_RUNNER_KEY)
      end

      it "snapshots the original tier_model_ids before the first rotation" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        expect(runner_state.preferred_tier_model_ids).to eq(
          "high" => "high-current", "mid" => "mid-current", "low" => "low-current"
        )
      end

      it "keeps the original snapshot across subsequent rotations" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")
        # Second rotation away from the already-rotated model.
        described_class.call(runner: runner, current_model_id: "high-other",
          user: user, current_tier: "high")

        expect(runner_state.preferred_tier_model_ids).to eq(
          "high" => "high-current", "mid" => "mid-current", "low" => "low-current"
        )
      end

      it "resets the rotating_tier_models flag so a later user save clears the snapshot" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")
        expect(runner.rotating_tier_models?).to be false

        # A subsequent user-initiated tier_model_ids change on the SAME
        # in-memory runner must clear the recovery snapshot. If the rotation
        # flag leaked truthy, this save would skip clear_free_model_rotation_snapshot
        # and leave a stale snapshot that a later recovery could revert.
        runner.update!(tier_model_ids: runner.tier_model_ids.merge("mid" => "high-other"))

        expect(runner_state.preferred_tier_model_ids).to be_nil
      end
    end

    describe ".restore_preferred!" do
      let(:tier_model_ids) { { "high" => "high-current", "mid" => "mid-current", "low" => "low-current" } }

      before { free_model(tier: "high", capability_score: 8.0, model_id: "high-other") }

      def runner_state
        user.runner_states.find_or_create_by!(runner_name: Runner::OPENROUTER_FREE_RUNNER_KEY)
      end

      it "restores the original tier_model_ids and clears the snapshot" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")
        expect(runner.reload.tier_model_ids["high"]).to eq("high-other")

        restored = described_class.restore_preferred!(runner: runner.reload, user: user)

        expect(restored).to be true
        expect(runner.reload.tier_model_ids).to eq(tier_model_ids)
        expect(runner_state.preferred_tier_model_ids).to be_nil
      end

      it "resets the rotating_tier_models flag after restoring" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")

        described_class.restore_preferred!(runner: runner.reload, user: user)

        expect(runner.rotating_tier_models?).to be false
      end

      it "returns false and is a no-op when no snapshot exists" do
        restored = described_class.restore_preferred!(runner: runner, user: user)

        expect(restored).to be false
        expect(runner.reload.tier_model_ids).to eq(tier_model_ids)
      end

      it "returns false for non-openrouter_free runners" do
        existing = user.runners.kept_only.find_by(runner_key: "claude")
        subscription_runner = existing || user.runners.create!(runner_key: "claude", auth_type: "subscription")

        expect(described_class.restore_preferred!(runner: subscription_runner, user: user)).to be false
      end

      it "is a graceful no-op when a snapshotted model was deleted since rotation" do
        described_class.call(runner: runner, current_model_id: "high-current",
          user: user, current_tier: "high")
        # openrouter_free requires every tier mapped, so a snapshot referencing
        # a now-deleted model cannot be restored; recovery must not break the
        # healthy runner. The snapshot is still cleared so it is not retried.
        LlmModel.find_by(model_id: "mid-current")&.destroy

        restored = described_class.restore_preferred!(runner: runner.reload, user: user)

        expect(restored).to be false
        expect(runner.reload.tier_model_ids["high"]).to eq("high-other")
        expect(runner_state.preferred_tier_model_ids).to be_nil
      end
    end
  end
end
