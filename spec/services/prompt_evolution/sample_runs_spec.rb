# frozen_string_literal: true

require "rails_helper"
require "set"

RSpec.describe PromptEvolution::SampleRuns do
  let(:project) { create(:project) }
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:prompt_version) { prompt.current_version }

  def create_completed_run(composite_score: 0.85, **attrs)
    run_attrs = {
      project: project,
      prompt_version: prompt_version,
      goal: "create_pr",
      cost_cents: 10,
      tokens_input: 1000,
      tokens_output: 500,
      duration_seconds: 120,
      completed_at: 1.day.ago
    }.merge(attrs)
    run_attrs[:source_pull_request_number] = 1 if run_attrs[:goal] == "review"
    run = create(:agent_run, :completed, run_attrs)
    create(:quality_metric, :automated, agent_run: run, prompt_version: prompt_version,
      composite_score: composite_score)
    run
  end

  describe ".call" do
    it "returns a Result with samples, prompt_stats, and evolution_candidates" do
      create_completed_run

      result = described_class.call(sample_size: 10, days: 7)

      expect(result).to be_a(described_class::Result)
      expect(result.samples).to be_an(Array)
      expect(result.prompt_stats).to be_a(Hash)
      expect(result.evolution_candidates).to be_an(Array)
    end

    it "returns empty results when no completed runs exist" do
      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples).to be_empty
      expect(result.prompt_stats).to be_empty
      expect(result.evolution_candidates).to be_empty
    end

    it "excludes runs without prompt versions" do
      create(:agent_run, :completed, project: project, prompt_version: nil, completed_at: 1.day.ago)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples).to be_empty
    end

    it "excludes runs with only human metrics" do
      run = create(:agent_run, :completed, project: project, prompt_version: prompt_version,
        completed_at: 1.day.ago)
      create(:quality_metric, :human, agent_run: run, prompt_version: prompt_version)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples.map { |sample| sample[:agent_run].id }).not_to include(run.id)
      expect(result.prompt_stats).to be_empty
    end

    it "excludes runs with nil automated composite scores" do
      run = create(:agent_run, :completed, project: project, prompt_version: prompt_version,
        completed_at: 1.day.ago)
      create(:quality_metric, :automated, agent_run: run, prompt_version: prompt_version,
        composite_score: nil)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples.map { |sample| sample[:agent_run].id }).not_to include(run.id)
      expect(result.prompt_stats).to be_empty
    end

    it "excludes runs outside the time window" do
      run = create(:agent_run, :completed, project: project, prompt_version: prompt_version,
        completed_at: 30.days.ago)
      create(:quality_metric, :automated, agent_run: run)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples).to be_empty
    end

    it "filters by project_id when provided" do
      other_project = create(:project)
      create_completed_run
      other_run = create(:agent_run, :completed, project: other_project,
        prompt_version: prompt_version, completed_at: 1.day.ago)
      create(:quality_metric, :automated, agent_run: other_run)

      result = described_class.call(sample_size: 10, days: 7, project_id: project.id)

      run_ids = result.samples.map { |s| s[:agent_run].id }
      expect(run_ids).not_to include(other_run.id)
    end
  end

  describe "stratified sampling" do
    it "samples across projects and goal types" do
      project2 = create(:project)
      create_completed_run(goal: "create_pr")
      create_completed_run(goal: "create_issue")
      run3 = create(:agent_run, :completed, project: project2,
        prompt_version: prompt_version, goal: "review", completed_at: 1.day.ago,
        source_pull_request_number: 1)
      create(:quality_metric, :automated, agent_run: run3)

      result = described_class.call(sample_size: 10, days: 7)

      goals = result.samples.map { |s| s[:goal] }
      expect(goals).to include("create_pr", "create_issue", "review")
    end

    it "does not bias selection toward the first strata when strata exceed sample size" do
      strata_projects = Array.new(10) { create(:project) }

      strata_projects.each_with_index do |strata_project, index|
        create_completed_run(
          project: strata_project,
          goal: "create_pr",
          completed_at: (index + 1).days.ago
        )
      end

      # Run multiple times to verify later strata can be selected
      all_selected_project_ids = Set.new
      10.times do
        result = described_class.call(sample_size: 3, days: 14)
        result.samples.each { |s| all_selected_project_ids << s[:project].id }
      end

      # With shuffling, projects beyond the first 3 must appear at least once.
      # Without randomization, only the first 3 strata would ever be selected.
      expect(all_selected_project_ids.size).to be > 3
    end

    it "respects sample_size limit" do
      8.times { create_completed_run }

      result = described_class.call(sample_size: 3, days: 7)

      expect(result.samples.size).to be <= 3
    end
  end

  describe "sample data collection" do
    it "includes prompt version, quality metrics, and cost data" do
      create_completed_run(cost_cents: 25, tokens_input: 2000, tokens_output: 800,
        duration_seconds: 300, composite_score: 0.92)

      result = described_class.call(sample_size: 10, days: 7)
      sample = result.samples.first

      expect(sample[:prompt_version]).to eq(prompt_version)
      expect(sample[:project]).to eq(project)
      expect(sample[:goal]).to eq("create_pr")
      expect(sample[:composite_score]).to eq(0.92)
      expect(sample[:cost_cents]).to eq(25)
      expect(sample[:tokens_input]).to eq(2000)
      expect(sample[:tokens_output]).to eq(800)
      expect(sample[:duration_seconds]).to eq(300)
    end
  end

  describe "prompt performance statistics" do
    it "calculates aggregate stats per prompt version" do
      create_completed_run(composite_score: 0.8)
      create_completed_run(composite_score: 0.9)
      create_completed_run(composite_score: 0.7)

      result = described_class.call(sample_size: 10, days: 7)
      stats = result.prompt_stats[prompt_version.id]

      expect(stats[:run_count]).to eq(3)
      expect(stats[:avg_score]).to be_within(1e-10).of(0.8)
      expect(stats[:min_score]).to eq(0.7)
      expect(stats[:max_score]).to eq(0.9)
      expect(stats[:median_score]).to eq(0.8)
      expect(stats[:prompt_version]).to eq(prompt_version)
    end

    it "includes goal breakdown in stats" do
      create_completed_run(goal: "create_pr", composite_score: 0.9)
      create_completed_run(goal: "create_issue", composite_score: 0.7)

      result = described_class.call(sample_size: 10, days: 7)
      stats = result.prompt_stats[prompt_version.id]

      expect(stats[:goal_breakdown]).to have_key("create_pr")
      expect(stats[:goal_breakdown]["create_pr"][:avg_score]).to eq(0.9)
      expect(stats[:goal_breakdown]["create_issue"][:avg_score]).to eq(0.7)
    end

    it "calculates average cost and duration" do
      create_completed_run(cost_cents: 10, duration_seconds: 100)
      create_completed_run(cost_cents: 20, duration_seconds: 200)

      result = described_class.call(sample_size: 10, days: 7)
      stats = result.prompt_stats[prompt_version.id]

      expect(stats[:avg_cost_cents]).to eq(15.0)
      expect(stats[:avg_duration_seconds]).to eq(150.0)
    end
  end

  describe "evolution candidate identification" do
    it "flags prompt versions with avg score below threshold" do
      6.times { create_completed_run(composite_score: 0.5) }

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.evolution_candidates.size).to eq(1)
      candidate = result.evolution_candidates.first
      expect(candidate[:prompt_version]).to eq(prompt_version)
      expect(candidate[:reasons]).to include(a_string_matching(/avg quality score.*below threshold/))
    end

    it "flags prompts with underperforming goal types" do
      3.times { create_completed_run(goal: "create_pr", composite_score: 0.9) }
      3.times { create_completed_run(goal: "create_issue", composite_score: 0.5) }

      result = described_class.call(sample_size: 10, days: 7)
      candidate = result.evolution_candidates.first

      expect(candidate[:reasons]).to include(a_string_matching(/create_issue.*below threshold/))
    end

    it "skips prompt versions with fewer than MIN_RUNS_FOR_EVALUATION runs" do
      2.times { create_completed_run(composite_score: 0.3) }

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.evolution_candidates).to be_empty
    end

    it "does not flag well-performing prompts" do
      6.times { create_completed_run(composite_score: 0.9) }

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.evolution_candidates).to be_empty
    end
  end
end
