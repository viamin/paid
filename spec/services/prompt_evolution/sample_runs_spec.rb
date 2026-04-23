# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolution::SampleRuns do
  let(:project) { create(:project) }
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:prompt_version) { prompt.current_version }

  def create_completed_run(composite_score: 0.85, **attrs)
    run = insert_completed_run(**attrs)
    insert_quality_metric(run: run, composite_score: composite_score)
    run
  end

  def insert_completed_run(**attrs)
    run_attrs = default_run_attrs.merge(attrs)
    run_attrs[:source_pull_request_number] = 1 if run_attrs[:goal] == "review"

    AgentRun.find(AgentRun.insert_all!([ agent_run_row(run_attrs) ], returning: %w[id]).rows.first.first)
  end

  def default_run_attrs
    {
      project: project,
      prompt_version: prompt_version,
      goal: "create_pr",
      cost_cents: 10,
      tokens_input: 1000,
      tokens_output: 500,
      duration_seconds: 120,
      completed_at: 1.day.ago
    }
  end

  def agent_run_row(attrs)
    now = Time.current
    {
      agent_type: "claude_code",
      custom_prompt: "Sample run",
      project_id: attrs[:project].id,
      prompt_version_id: attrs[:prompt_version]&.id,
      source_pull_request_number: attrs[:source_pull_request_number],
      status: "completed",
      goal: attrs[:goal],
      trigger_type: "automatic",
      proxy_token: SecureRandom.hex(32),
      cost_cents: attrs[:cost_cents],
      tokens_input: attrs[:tokens_input],
      tokens_output: attrs[:tokens_output],
      duration_seconds: attrs[:duration_seconds],
      started_at: attrs[:completed_at] - attrs[:duration_seconds].seconds,
      completed_at: attrs[:completed_at],
      result_commit_sha: "abc123def456789012345678901234567890abcd",
      pull_request_url: "https://github.com/example/repo/pull/1",
      pull_request_number: 1,
      created_at: now,
      updated_at: now
    }
  end

  def insert_quality_metric(run:, composite_score:, metric_type: "automated", version: prompt_version, scores: {})
    now = Time.current
    QualityMetric.insert_all!([
      {
        agent_run_id: run.id,
        prompt_version_id: version&.id,
        metric_type: metric_type,
        feedback_source: metric_type == "human" ? "pr_merge" : "system",
        composite_score: composite_score,
        scores: scores,
        created_at: now,
        updated_at: now
      }
    ])
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
      insert_completed_run(prompt_version: nil, completed_at: 1.day.ago)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples).to be_empty
    end

    it "excludes runs with only human metrics" do
      run = insert_completed_run(project: project, prompt_version: prompt_version, completed_at: 1.day.ago)
      insert_quality_metric(run: run, metric_type: "human", composite_score: 1.0)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples.map { |sample| sample[:agent_run].id }).not_to include(run.id)
      expect(result.prompt_stats).to be_empty
    end

    it "excludes runs with nil automated composite scores" do
      run = insert_completed_run(project: project, prompt_version: prompt_version, completed_at: 1.day.ago)
      insert_quality_metric(run: run, composite_score: nil)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples.map { |sample| sample[:agent_run].id }).not_to include(run.id)
      expect(result.prompt_stats).to be_empty
    end

    it "excludes runs outside the time window" do
      run = insert_completed_run(project: project, prompt_version: prompt_version, completed_at: 30.days.ago)
      insert_quality_metric(run: run, composite_score: 0.85)

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples).to be_empty
    end

    it "filters by project_id when provided" do
      other_project = create(:project)
      create_completed_run
      other_run = insert_completed_run(project: other_project, prompt_version: prompt_version, completed_at: 1.day.ago)
      insert_quality_metric(run: other_run, composite_score: 0.85)

      result = described_class.call(sample_size: 10, days: 7, project_id: project.id)

      run_ids = result.samples.map { |s| s[:agent_run].id }
      expect(run_ids).not_to include(other_run.id)
    end

    it "samples only low-quality runs when failure_only is enabled" do
      failing_run = create_completed_run(composite_score: 0.2)
      healthy_run = create_completed_run(composite_score: 0.9)

      result = described_class.call(
        sample_size: 10,
        days: 7,
        failure_only: true,
        metric_type: "composite_score",
        threshold: 0.5,
        min_runs_for_evaluation: 1
      )

      run_ids = result.samples.map { |sample| sample[:agent_run].id }
      expect(run_ids).to include(failing_run.id)
      expect(run_ids).not_to include(healthy_run.id)
    end

    it "identifies metric-specific failures as evolution candidates" do
      3.times do
        run = insert_completed_run(project: project, prompt_version: prompt_version, completed_at: 1.day.ago)
        insert_quality_metric(run: run, composite_score: 0.9, scores: { "reaction_score" => 0.1 })
      end

      result = described_class.call(
        sample_size: 10,
        days: 7,
        failure_only: true,
        metric_type: "reaction_score",
        threshold: 0.5,
        min_runs_for_evaluation: 3
      )

      candidate = result.evolution_candidates.first
      expect(candidate[:prompt_version]).to eq(prompt_version)
      expect(candidate[:reasons]).to include(a_string_matching(/reaction_score avg score.*targeted threshold/))
    end
  end

  describe "stratified sampling" do
    it "samples across projects and goal types" do
      project2 = create(:project)
      create_completed_run(goal: "create_pr")
      create_completed_run(goal: "create_issue")
      run3 = insert_completed_run(project: project2,
        prompt_version: prompt_version, goal: "review", completed_at: 1.day.ago,
        source_pull_request_number: 1)
      insert_quality_metric(run: run3, composite_score: 0.85)

      result = described_class.call(sample_size: 10, days: 7)

      goals = result.samples.map { |s| s[:goal] }
      expect(goals).to include("create_pr", "create_issue", "review")
    end

    it "does not bias selection toward the first strata when strata exceed sample size" do
      strata_projects = Array.new(5) { create(:project) }

      strata_projects.each_with_index do |strata_project, index|
        create_completed_run(
          project: strata_project,
          goal: "create_pr",
          completed_at: (index + 1).days.ago
        )
      end

      result = described_class.call(sample_size: 3, days: 14, random: Random.new(1))
      selected_project_ids = result.samples.map { |s| s[:project].id }

      # With shuffling, projects beyond the first 3 can be selected.
      # Without randomization, only the first 3 strata would be selected.
      expect(selected_project_ids & strata_projects.drop(3).map(&:id)).not_to be_empty
    end

    it "returns exactly sample_size when enough runs exist and strata don't divide evenly" do
      # 3 strata with 4 runs each = 12 runs, sample_size = 10, 10 % 3 != 0
      3.times do |i|
        proj = create(:project)
        4.times { create_completed_run(project: proj, goal: "create_pr") }
      end

      result = described_class.call(sample_size: 10, days: 7)

      expect(result.samples.size).to eq(10)
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
