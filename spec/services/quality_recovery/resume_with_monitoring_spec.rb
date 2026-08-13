# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::ResumeWithMonitoring do
  describe ".call" do
    let(:project) { create(:project) }

    before do
      allow(QualityMetrics::TrendAnalysis).to receive(:call).and_return(
        rolling_average: 0.65, sample_size: 5, recent_scores: [], min_score: 0.5, max_score: 0.8
      )
    end

    context "with a paused run" do
      let!(:paused_run) { create(:agent_run, :paused, project: project) }

      it "resumes the paused run" do
        result = described_class.call(project: project)

        expect(paused_run.reload.status).to eq("queued")
        expect(result.resumed_run).to eq(paused_run)
      end

      it "creates a recovery action record" do
        expect {
          described_class.call(project: project)
        }.to change(QualityRecoveryAction, :count).by(1)
      end

      it "records quality_before and monitoring parameters" do
        result = described_class.call(project: project, quality_threshold: 0.8)

        action = result.recovery_action
        expect(action.quality_before).to eq(0.65)
        expect(action.parameters["quality_threshold"]).to eq(0.8)
      end

      it "links the recovery action to the resumed agent run" do
        result = described_class.call(project: project)

        expect(result.recovery_action.agent_run).to eq(paused_run)
      end

      it "includes diagnosis in the recovery action" do
        result = described_class.call(project: project)

        expect(result.recovery_action.diagnosis).to include("project_id" => project.id)
      end

      it "resumes the oldest paused run first" do
        older_paused = create(:agent_run, :paused, project: project, paused_at: 1.hour.ago)

        result = described_class.call(project: project)

        expect(result.resumed_run).to eq(older_paused)
      end
    end

    context "with no paused runs" do
      it "creates a recovery action with no_paused_runs status" do
        result = described_class.call(project: project)

        expect(result.resumed_run).to be_nil
        expect(result.recovery_action.result["status"]).to eq("no_paused_runs")
      end
    end

    context "with custom parameters" do
      before { create(:agent_run, :paused, project: project) }

      it "uses custom quality threshold and evaluation window" do
        result = described_class.call(
          project: project,
          quality_threshold: 0.9,
          evaluation_window: 10
        )

        action = result.recovery_action
        expect(action.parameters["quality_threshold"]).to eq(0.9)
        expect(action.parameters["evaluation_window"]).to eq(10)
      end
    end
  end
end
