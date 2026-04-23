# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::ExecuteAction do
  describe ".call" do
    let(:project) { create(:project) }

    before do
      allow(QualityMetrics::TrendAnalysis).to receive(:call).and_return(
        rolling_average: 0.65, sample_size: 10, recent_scores: [], min_score: 0.4, max_score: 0.9
      )
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    context "with prompt rollback" do
      let(:prompt) { create(:prompt, project: project) }
      let!(:previous_version) { prompt.create_version!(template: "v1 template") }
      let!(:current_version) { prompt.create_version!(template: "v2 template") }

      it "rolls back the prompt to the specified version" do
        result = described_class.call(
          project: project,
          action_type: "prompt_rollback",
          parameters: {
            prompt_id: prompt.id,
            from_version_id: current_version.id,
            to_version_id: previous_version.id
          }
        )

        expect(result).to be_success
        expect(prompt.reload.current_version).to eq(previous_version)
      end

      it "creates a recovery action record" do
        expect {
          described_class.call(
            project: project,
            action_type: "prompt_rollback",
            parameters: {
              prompt_id: prompt.id,
              from_version_id: current_version.id,
              to_version_id: previous_version.id
            }
          )
        }.to change(QualityRecoveryAction, :count).by(1)
      end

      it "records quality_before from trend analysis" do
        result = described_class.call(
          project: project,
          action_type: "prompt_rollback",
          parameters: {
            prompt_id: prompt.id,
            from_version_id: current_version.id,
            to_version_id: previous_version.id
          }
        )

        expect(result.recovery_action.quality_before).to eq(0.65)
      end

      it "sets the prompt_version on the recovery action" do
        result = described_class.call(
          project: project,
          action_type: "prompt_rollback",
          parameters: {
            prompt_id: prompt.id,
            from_version_id: current_version.id,
            to_version_id: previous_version.id
          }
        )

        expect(result.recovery_action.prompt_version).to eq(previous_version)
      end

      it "auto-resumes a quality-paused project after rollback" do
        project.update!(quality_paused_at: 1.hour.ago)

        result = described_class.call(
          project: project,
          action_type: "prompt_rollback",
          parameters: {
            prompt_id: prompt.id,
            from_version_id: current_version.id,
            to_version_id: previous_version.id
          }
        )

        expect(result.auto_resume_result).to be_resumed
        expect(project.reload).not_to be_quality_paused
        expect(project.quality_pause_events.resumes.last.metadata).to include(
          "reason" => "quality_recovery_prompt_rollback",
          "recovery_action_id" => result.recovery_action.id
        )
      end
    end

    context "with model change" do
      it "applies the agent preference" do
        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            from_agent_type: "claude_code",
            to_agent_type: "cursor"
          }
        )

        expect(result).to be_success
        expect(result.recovery_action.result).to include(
          "status" => "changed",
          "preference_type" => "agent",
          "from_agent_type" => "claude_code",
          "to_agent_type" => "cursor"
        )
        expect(project.created_by.settings.reload.default_agent_provider).to eq(
          project.created_by.providers.find_by!(provider_key: "cursor").routing_key
        )
      end

      it "updates goal-specific preferences that still point at the old agent" do
        owner = project.created_by
        cursor = create(:provider, user: owner, provider_key: "cursor")
        codex = create(:provider, user: owner, provider_key: "codex")
        owner.settings.update!(
          default_agent_providers_by_goal: {
            "create_pr" => owner.providers.find_by!(provider_key: "claude").routing_key,
            "review" => codex.routing_key
          }
        )

        execute_model_change(from_agent_type: "claude_code", to_agent_type: "cursor")

        expect(owner.settings.reload.default_agent_providers_by_goal).to eq(
          "create_pr" => cursor.routing_key,
          "review" => codex.routing_key
        )
      end

      it "applies the required model preference" do
        model = create(:llm_model, model_id: "claude-sonnet-test")

        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            to_model_id: model.model_id
          }
        )

        expect(result).to be_success
        expect(result.recovery_action.result).to include(
          "status" => "changed",
          "preference_type" => "model",
          "to_model_id" => model.model_id
        )
        expect(project.reload.model_preferences["required_model_id"]).to eq(model.model_id)
      end

      it "auto-resumes a quality-paused project after applying the model change" do
        project.update!(quality_paused_at: 1.hour.ago)

        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            from_agent_type: "claude_code",
            to_agent_type: "cursor"
          }
        )

        expect(result.auto_resume_result).to be_resumed
        expect(project.reload).not_to be_quality_paused
        expect(project.quality_pause_events.resumes.last.metadata).to include(
          "reason" => "quality_recovery_model_change",
          "recovery_action_id" => result.recovery_action.id
        )
      end

      it "auto-resumes a quality-paused project after applying the required model preference" do
        model = create(:llm_model, model_id: "claude-opus-test")
        project.update!(quality_paused_at: 1.hour.ago)

        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            to_model_id: model.model_id
          }
        )

        expect(result.auto_resume_result).to be_resumed
        expect(project.reload).not_to be_quality_paused
        expect(project.model_preferences["required_model_id"]).to eq(model.model_id)
      end

      it "does not auto-resume when the action only records a recommendation" do
        project.update!(quality_paused_at: 1.hour.ago)

        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            adjustment_type: "provider_switch"
          }
        )

        expect(result.recovery_action.result["status"]).to eq("recommended")
        expect(result.auto_resume_result).to be_nil
        expect(project.reload).to be_quality_paused
      end
    end

    context "with config adjustment" do
      it "records the config adjustment recommendation" do
        result = described_class.call(
          project: project,
          action_type: "config_adjustment",
          parameters: {
            adjustment_type: "review_settings",
            suggestions: [ "Enable stricter review settings" ]
          }
        )

        expect(result).to be_success
        expect(result.recovery_action.result["status"]).to eq("recommended")
      end

      it "does not auto-resume because the configuration has not changed yet" do
        project.update!(quality_paused_at: 1.hour.ago)

        result = described_class.call(
          project: project,
          action_type: "config_adjustment",
          parameters: {
            adjustment_type: "review_settings",
            suggestions: [ "Enable stricter review settings" ]
          }
        )

        expect(result.auto_resume_result).to be_nil
        expect(project.reload).to be_quality_paused
      end
    end

    context "when execution fails" do
      it "marks the action as failed and returns unsuccessful result" do
        result = described_class.call(
          project: project,
          action_type: "prompt_rollback",
          parameters: { prompt_id: -1, to_version_id: -1 }
        )

        expect(result).not_to be_success
        expect(result.recovery_action.status).to eq("failed")
        expect(result.error).to be_present
      end
    end
  end

  def execute_model_change(parameters)
    described_class.call(project: project, action_type: "model_change", parameters: parameters)
  end
end
