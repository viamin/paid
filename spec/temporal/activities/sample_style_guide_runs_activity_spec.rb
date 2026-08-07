# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::SampleStyleGuideRunsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:project) { create(:project) }
    let(:style_guide) { create(:style_guide, :for_account, account: project.account) }
    let(:current_version) do
      version = create(:style_guide_version, style_guide: style_guide, created_by: "test")
      style_guide.update_column(:current_version_id, version.id)
      version
    end

    let(:input) { { style_guide_id: style_guide.id, project_id: project.id } }

    def create_run_with_exposure(version:, composite_score:)
      run = create(:agent_run, :completed,
        project: project,
        goal: "create_pr",
        completed_at: 1.day.ago,
        cost_cents: 10,
        duration_seconds: 120)
      create(:quality_metric, :automated, agent_run: run, composite_score: composite_score)
      create(:style_guide_run_exposure,
        agent_run: run,
        style_guide: style_guide,
        style_guide_version: version,
        guide_name: style_guide.name,
        source_scope: "account",
        position: 0,
        injected_via: "spec",
        injected_content: version.raw_content)
      run
    end

    context "when the current version underperforms" do
      before do
        StyleGuideEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION.times do
          create_run_with_exposure(version: current_version, composite_score: 0.3)
        end
      end

      # @spec STYLE-GUIDE-EVOLUTION-006
      it "returns the current version as an evolution candidate" do
        result = activity.execute(input)

        expect(result[:evolution_candidates]).not_to be_empty
        expect(result[:evolution_candidates]).to all(include(style_guide_version_id: current_version.id))
      end

      it "includes quality metrics" do
        result = activity.execute(input)

        expect(result[:quality_metrics]).to be_an(Array)
        expect(result[:quality_metrics]).to all(include(:composite_score))
      end
    end

    context "when only a historical variant underperforms but the current version is healthy" do
      let(:old_variant) do
        create(:style_guide_version,
          style_guide: style_guide,
          raw_content: "old variant content",
          created_by: "ab_test")
      end

      before do
        # Current version is healthy
        StyleGuideEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION.times do
          create_run_with_exposure(version: current_version, composite_score: 0.9)
        end

        # Old variant underperforms — must not trigger evolution
        StyleGuideEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION.times do
          create_run_with_exposure(version: old_variant, composite_score: 0.2)
        end
      end

      it "returns no evolution candidates" do
        result = activity.execute(input)

        expect(result[:evolution_candidates]).to be_empty
      end
    end

    context "when the style guide has no runs" do
      it "returns empty candidates" do
        result = activity.execute(input)

        expect(result[:evolution_candidates]).to be_empty
      end
    end

    context "with an invalid style_guide_id" do
      it "raises ActiveRecord::RecordNotFound" do
        expect {
          activity.execute(input.merge(style_guide_id: -1))
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
