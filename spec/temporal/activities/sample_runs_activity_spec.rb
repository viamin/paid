# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::SampleRunsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:project) { create(:project) }
    let(:prompt) { create(:prompt, :global, :with_version) }
    let(:prompt_version) { prompt.current_version }

    let(:input) do
      { prompt_id: prompt.id, project_id: project.id, sample_size: 10, sample_days: 14 }
    end

    def create_run_with_metric(goal:, composite_score:, scores:)
      run = create(:agent_run, :completed,
        project: project,
        prompt_version: prompt_version,
        goal: goal,
        completed_at: 1.day.ago,
        cost_cents: 10,
        duration_seconds: 120)
      create(:quality_metric, :automated, agent_run: run,
        prompt_version: prompt_version,
        composite_score: composite_score,
        scores: scores)
    end

    def create_failing_run(version)
      create(:agent_run, :completed,
        project: project,
        prompt_version: version,
        goal: "create_pr",
        completed_at: 1.day.ago,
        cost_cents: 10,
        duration_seconds: 120).tap do |run|
        create(:quality_metric, :automated, agent_run: run,
          prompt_version: version, composite_score: 0.2)
      end
    end

    context "with completed runs" do
      before do
        3.times do
          run = create(:agent_run, :completed,
            project: project,
            prompt_version: prompt_version,
            goal: "create_pr",
            completed_at: 1.day.ago,
            cost_cents: 10,
            duration_seconds: 120)
          create(:quality_metric, :automated, agent_run: run,
            prompt_version: prompt_version, composite_score: 0.5)
        end
      end

      it "returns sample data scoped to the prompt" do
        result = activity.execute(input)

        expect(result[:prompt_id]).to eq(prompt.id)
        expect(result[:total_samples]).to be_positive
      end

      it "returns serializable evolution candidates" do
        result = activity.execute(input)

        expect(result[:evolution_candidates]).to all(include(:prompt_version_id, :avg_score, :run_count, :reasons))
      end

      it "extracts sample outputs for mutation" do
        result = activity.execute(input)

        expect(result[:sample_outputs]).to include(:successes, :failures)
      end

      it "classifies successes with the targeted metric and threshold" do
        create_run_with_metric(goal: "create_pr", composite_score: 0.9, scores: { "reaction_score" => 0.2 })
        create_run_with_metric(goal: "create_issue", composite_score: 0.6, scores: { "reaction_score" => 0.8 })

        result = activity.execute(input.merge(
          metric_type: "reaction_score",
          threshold: 0.5,
          min_runs_for_evaluation: 1
        ))

        successes = result[:sample_outputs][:successes].join("\n")
        expect(successes).to include("Goal: create_issue")
        expect(successes).not_to include("Goal: create_pr")
      end

      it "extracts quality metrics" do
        result = activity.execute(input)

        expect(result[:quality_metrics]).to be_an(Array)
        expect(result[:quality_metrics]).to all(include(:composite_score))
      end

      it "passes prompt_id through to sampling so targeted failures stay eligible" do
        other_prompt = create(:prompt, :global, :with_version)

        5.times do
          create_failing_run(prompt_version)
          create_failing_run(other_prompt.current_version)
        end

        result = activity.execute(input.merge(
          sample_size: 5,
          failure_only: true,
          threshold: 0.5,
          min_runs_for_evaluation: 3
        ))

        expect(result[:evolution_candidates]).to all(include(prompt_version_id: prompt_version.id))
        expect(result[:total_samples]).to eq(5)
      end
    end

    context "with no completed runs" do
      it "returns empty candidates" do
        result = activity.execute(input)

        expect(result[:evolution_candidates]).to be_empty
        expect(result[:total_samples]).to eq(0)
      end
    end

    context "with invalid prompt_id" do
      it "raises ActiveRecord::RecordNotFound" do
        expect {
          activity.execute(input.merge(prompt_id: -1))
        }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
