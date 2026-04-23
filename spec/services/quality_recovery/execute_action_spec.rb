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
      it "records the model change recommendation" do
        result = described_class.call(
          project: project,
          action_type: "model_change",
          parameters: {
            from_agent_type: "claude_code",
            to_agent_type: "cursor"
          }
        )

        expect(result).to be_success
        expect(result.recovery_action.result["status"]).to eq("recommended")
      end

      it "auto-resumes a quality-paused project" do
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
end
