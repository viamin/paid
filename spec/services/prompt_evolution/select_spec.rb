# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolution::Select do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:v1) { prompt.current_version }
  let(:metric_project) { create(:project) }

  def add_version(parent: nil)
    next_version = (prompt.prompt_versions.maximum(:version) || 0) + 1
    create(:prompt_version,
      prompt: prompt,
      version: next_version,
      parent_version: parent,
      template: "Variant #{next_version} for {{title}} {{body}}"
    )
  end

  def add_metrics(version, scores:)
    now = Time.current
    score_list = Array(scores)
    run_ids = insert_metric_runs(version, score_list.size, now: now)
    metric_rows = run_ids.zip(score_list).map do |run_id, score|
      metric_row(run_id: run_id, version: version, score: score, metric_type: "automated", now: now)
    end
    return if metric_rows.empty?

    QualityMetric.insert_all!(metric_rows)
  end

  def add_metric(version, score:, metric_type:)
    now = Time.current
    run_id = insert_metric_runs(version, 1, now: now).first
    QualityMetric.insert_all!([
      metric_row(run_id: run_id, version: version, score: score, metric_type: metric_type, now: now)
    ])
  end

  def insert_metric_runs(version, count, now:)
    return [] if count.zero?

    rows = Array.new(count) do
      {
        agent_type: "claude_code",
        custom_prompt: "Metric run",
        project_id: metric_project.id,
        prompt_version_id: version.id,
        status: "pending",
        goal: "create_pr",
        trigger_type: "automatic",
        proxy_token: SecureRandom.hex(32),
        created_at: now,
        updated_at: now
      }
    end

    AgentRun.insert_all!(rows, returning: %w[id]).rows.flatten
  end

  def metric_row(run_id:, version:, score:, metric_type:, now:)
    {
      agent_run_id: run_id,
      prompt_version_id: version.id,
      metric_type: metric_type,
      feedback_source: metric_type == "human" ? "pr_merge" : "system",
      composite_score: score,
      created_at: now,
      updated_at: now
    }
  end

  describe ".call" do
    it "returns insufficient_data when no version has enough samples" do
      add_metrics(v1, scores: [ 0.9 ])

      result = described_class.call(prompt: prompt, min_samples: 3)

      expect(result.winner).to be_nil
      expect(result.reason).to eq(:insufficient_data)
      expect(result.promoted).to be(false)
      expect(result.retired).to be_empty
    end

    it "promotes the fittest version via tournament selection" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.4, 0.5, 0.45 ])
      add_metrics(v2, scores: [ 0.9, 0.92, 0.88 ])
      add_metrics(v3, scores: [ 0.6, 0.65, 0.7 ])

      result = described_class.call(
        prompt: prompt,
        tournament_size: 3,
        rounds: 10,
        retirement_threshold: 0.0,
        random: Random.new(42)
      )

      expect(result.winner).to eq(v2)
      expect(result.promoted).to be(true)
      expect(result.reason).to eq(:selected)
      expect(prompt.reload.current_version).to eq(v2)
    end

    it "does not promote when the fittest is already the current version" do
      v2 = add_version(parent: v1)
      prompt.update!(current_version: v2)

      add_metrics(v1, scores: [ 0.3, 0.35, 0.4 ])
      add_metrics(v2, scores: [ 0.9, 0.92, 0.88 ])

      result = described_class.call(
        prompt: prompt,
        rounds: 5,
        retirement_threshold: 0.0,
        random: Random.new(1)
      )

      expect(result.winner).to eq(v2)
      expect(result.promoted).to be(false)
      expect(prompt.reload.current_version).to eq(v2)
    end

    it "computes fitness only from automated metrics with composite_score" do
      v2 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.5, 0.5, 0.5 ])
      3.times do
        add_metric(v2, score: 1.0, metric_type: "human")
      end
      add_metrics(v2, scores: [ 0.8, 0.82, 0.81 ])

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.0,
        random: Random.new(3)
      )

      expect(result.fitness[v2.id]).to be_within(0.01).of(0.81)
    end

    it "retires underperformers below the retirement threshold" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v1)
      v4 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.2, 0.25, 0.22 ])
      add_metrics(v2, scores: [ 0.9, 0.92, 0.88 ])
      add_metrics(v3, scores: [ 0.3, 0.32, 0.35 ])
      add_metrics(v4, scores: [ 0.85, 0.83, 0.87 ])

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.5,
        min_diversity: 2,
        rounds: 5,
        random: Random.new(7)
      )

      retired_ids = result.retired.map(&:id)
      expect(retired_ids).to contain_exactly(v1.id, v3.id)
      expect(v1.reload.retired_at).to be_present
      expect(v3.reload.retired_at).to be_present
    end

    it "preserves minimum diversity when retiring underperformers" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v1)

      # All three perform poorly; winner is the least bad, so only the worst
      # single version can retire before we hit min_diversity=2.
      add_metrics(v1, scores: [ 0.1, 0.12, 0.11 ])
      add_metrics(v2, scores: [ 0.2, 0.21, 0.22 ])
      add_metrics(v3, scores: [ 0.3, 0.31, 0.29 ])

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.5,
        min_diversity: 2,
        rounds: 5,
        random: Random.new(9)
      )

      # v3 wins (highest fitness), v1 is worst — retirement stops after v1 so
      # we keep at least min_diversity=2 active (v2 and v3).
      active_ids = prompt.prompt_versions.active.pluck(:id)
      expect(active_ids.size).to be >= 2
      expect(result.retired.size).to be <= 1
    end

    it "never retires the winner even when all versions are below the threshold" do
      v2 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.1, 0.15, 0.12 ])
      add_metrics(v2, scores: [ 0.2, 0.22, 0.21 ])

      prompt.update!(current_version: v1)

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.9,
        min_diversity: 0,
        rounds: 5,
        random: Random.new(11)
      )

      expect(result.winner).to be_present
      expect(result.retired.map(&:id)).not_to include(result.winner.id)
      expect(result.winner.reload.retired_at).to be_nil
    end

    it "rolls back to the fittest ancestor when current version regresses" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v2)

      add_metrics(v1, scores: [ 0.6, 0.62, 0.61 ])
      add_metrics(v2, scores: [ 0.9, 0.92, 0.88 ])
      add_metrics(v3, scores: [ 0.4, 0.42, 0.41 ])

      # Force tournaments to pick only v3 so rollback has something to detect.
      allow(described_class::Tournament).to receive(:call).and_return(v3)

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.0,
        rollback_drop: 0.1
      )

      expect(result.rolled_back).to be(true)
      expect(result.winner).to eq(v2)
      expect(result.reason).to eq(:rolled_back)
      expect(prompt.reload.current_version).to eq(v2)
    end

    it "does not rollback when the ancestor is only marginally better" do
      v2 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.82, 0.81, 0.80 ])
      add_metrics(v2, scores: [ 0.78, 0.79, 0.77 ])

      allow(described_class::Tournament).to receive(:call).and_return(v2)

      result = described_class.call(
        prompt: prompt,
        retirement_threshold: 0.0,
        rollback_drop: 0.1
      )

      expect(result.rolled_back).to be(false)
      expect(result.winner).to eq(v2)
    end

    it "excludes retired versions from selection" do
      v2 = add_version(parent: v1)

      add_metrics(v1, scores: [ 0.9, 0.92, 0.88 ])
      add_metrics(v2, scores: [ 0.4, 0.42, 0.41 ])

      v1.update!(retired_at: Time.current)

      result = described_class.call(prompt: prompt, retirement_threshold: 0.0)

      expect(result.winner).to eq(v2)
      expect(result.fitness.keys).to contain_exactly(v2.id)
    end

    it "builds a generation map from the parent_version chain" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v2)
      v4 = add_version(parent: nil)

      add_metrics(v1, scores: [ 0.5, 0.5, 0.5 ])
      add_metrics(v2, scores: [ 0.5, 0.5, 0.5 ])
      add_metrics(v3, scores: [ 0.5, 0.5, 0.5 ])
      add_metrics(v4, scores: [ 0.5, 0.5, 0.5 ])

      result = described_class.call(prompt: prompt, retirement_threshold: 0.0)

      expect(result.generations[v1.id]).to eq(0)
      expect(result.generations[v2.id]).to eq(1)
      expect(result.generations[v3.id]).to eq(2)
      expect(result.generations[v4.id]).to eq(0)
    end

    it "caps generation depth on circular parent references" do
      v2 = add_version(parent: v1)
      v3 = add_version(parent: v2)
      # Create a cycle: v1.parent_version = v3
      v1.update_column(:parent_version_id, v3.id)

      add_metrics(v1, scores: [ 0.5, 0.5, 0.5 ])
      add_metrics(v2, scores: [ 0.5, 0.5, 0.5 ])
      add_metrics(v3, scores: [ 0.5, 0.5, 0.5 ])

      expect {
        described_class.call(prompt: prompt, retirement_threshold: 0.0)
      }.not_to raise_error
    end
  end
end
