# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolution::FitnessFunction do
  def sample(composite_score: 0.8, cost_cents: 100, duration_seconds: 600, **extras)
    {
      composite_score: composite_score,
      cost_cents: cost_cents,
      duration_seconds: duration_seconds,
      **extras
    }
  end

  describe ".call" do
    it "returns a Result with composite, dimension scores, and metadata" do
      result = described_class.call(samples: [ sample ])

      expect(result).to be_a(described_class::Result)
      expect(result.composite_fitness).to be_a(Numeric)
      expect(result.quality_score).to be_a(Numeric)
      expect(result.cost_score).to be_a(Numeric)
      expect(result.speed_score).to be_a(Numeric)
      expect(result.sample_count).to eq(1)
      expect(result.weights.keys).to match_array(described_class::DIMENSIONS)
      expect(result.reference_cost_cents).to eq(described_class::DEFAULT_REFERENCE_COST_CENTS)
      expect(result.reference_duration_seconds).to eq(described_class::DEFAULT_REFERENCE_DURATION_SECONDS)
    end

    it "returns zero scores for an empty sample set" do
      result = described_class.call(samples: [])

      expect(result.sample_count).to eq(0)
      expect(result.composite_fitness).to eq(0.0)
      expect(result.quality_score).to eq(0.0)
      expect(result.cost_score).to eq(0.0)
      expect(result.speed_score).to eq(0.0)
    end

    it "averages composite_score values for the quality dimension" do
      result = described_class.call(samples: [
        sample(composite_score: 0.6),
        sample(composite_score: 0.8),
        sample(composite_score: 1.0)
      ])

      expect(result.quality_score).to be_within(1e-4).of(0.8)
    end

    it "clamps out-of-range composite_score values to [0, 1]" do
      result = described_class.call(samples: [
        sample(composite_score: -0.5),
        sample(composite_score: 1.5)
      ])

      expect(result.quality_score).to eq(0.5)
    end

    it "uses 0.5 cost_score when cost equals the reference value" do
      result = described_class.call(
        samples: [ sample(cost_cents: 100) ],
        reference_cost_cents: 100
      )

      expect(result.cost_score).to be_within(1e-4).of(0.5)
    end

    it "rewards lower-cost samples with a higher cost_score" do
      cheap = described_class.call(samples: [ sample(cost_cents: 10) ], reference_cost_cents: 100)
      expensive = described_class.call(samples: [ sample(cost_cents: 1000) ], reference_cost_cents: 100)

      expect(cheap.cost_score).to be > expensive.cost_score
      expect(cheap.cost_score).to be_within(1e-4).of(100.0 / 110.0)
      expect(expensive.cost_score).to be_within(1e-4).of(100.0 / 1100.0)
    end

    it "uses 0.5 speed_score when duration equals the reference value" do
      result = described_class.call(
        samples: [ sample(duration_seconds: 600) ],
        reference_duration_seconds: 600
      )

      expect(result.speed_score).to be_within(1e-4).of(0.5)
    end

    it "rewards faster runs with a higher speed_score" do
      fast = described_class.call(samples: [ sample(duration_seconds: 60) ], reference_duration_seconds: 600)
      slow = described_class.call(samples: [ sample(duration_seconds: 6_000) ], reference_duration_seconds: 600)

      expect(fast.speed_score).to be > slow.speed_score
    end

    it "treats negative cost or duration as zero (best-case)" do
      result = described_class.call(samples: [ sample(cost_cents: -50, duration_seconds: -10) ])

      expect(result.cost_score).to be_within(1e-4).of(1.0)
      expect(result.speed_score).to be_within(1e-4).of(1.0)
    end

    it "skips samples missing a dimension when averaging that dimension" do
      result = described_class.call(samples: [
        { composite_score: 0.9, duration_seconds: 600 }, # no cost_cents
        { composite_score: 0.5, cost_cents: 100, duration_seconds: 600 }
      ])

      # quality averages both samples; cost only the one with cost_cents
      expect(result.quality_score).to be_within(1e-4).of(0.7)
      expect(result.cost_score).to be_within(1e-4).of(0.5)
    end

    it "supports samples with string keys" do
      result = described_class.call(samples: [
        { "composite_score" => 0.8, "cost_cents" => 100, "duration_seconds" => 600 }
      ])

      expect(result.quality_score).to eq(0.8)
      expect(result.cost_score).to be_within(1e-4).of(0.5)
      expect(result.speed_score).to be_within(1e-4).of(0.5)
    end

    it "supports samples with method-style accessors (struct-like objects)" do
      sample_struct = Struct.new(:composite_score, :cost_cents, :duration_seconds, keyword_init: true)

      result = described_class.call(samples: [
        sample_struct.new(composite_score: 0.6, cost_cents: 100, duration_seconds: 600)
      ])

      expect(result.quality_score).to eq(0.6)
    end
  end

  describe "composite weighting" do
    it "applies the default 0.6/0.2/0.2 weighting" do
      result = described_class.call(samples: [ sample(composite_score: 1.0, cost_cents: 100, duration_seconds: 600) ])

      expected = (0.6 * 1.0) + (0.2 * 0.5) + (0.2 * 0.5)
      expect(result.composite_fitness).to be_within(1e-4).of(expected)
    end

    it "respects explicit weights override" do
      result = described_class.call(
        samples: [ sample(composite_score: 1.0, cost_cents: 100, duration_seconds: 600) ],
        weights: { quality: 1.0, cost: 0.0, speed: 0.0 }
      )

      expect(result.composite_fitness).to be_within(1e-4).of(1.0)
      expect(result.weights[:quality]).to eq(1.0)
    end

    it "renormalizes weights so they sum to 1.0" do
      result = described_class.call(
        samples: [ sample ],
        weights: { quality: 6.0, cost: 2.0, speed: 2.0 }
      )

      expect(result.weights.values.sum).to be_within(1e-4).of(1.0)
      expect(result.weights[:quality]).to be_within(1e-4).of(0.6)
    end

    it "accepts string-keyed weights" do
      result = described_class.call(
        samples: [ sample ],
        weights: { "quality" => 0.5, "cost" => 0.25, "speed" => 0.25 }
      )

      expect(result.weights[:quality]).to be_within(1e-4).of(0.5)
      expect(result.weights[:cost]).to be_within(1e-4).of(0.25)
    end

    it "falls back to defaults when all weights are zero" do
      result = described_class.call(
        samples: [ sample ],
        weights: { quality: 0, cost: 0, speed: 0 }
      )

      expect(result.weights).to eq(described_class::DEFAULT_WEIGHTS)
    end

    it "fills in missing dimensions from defaults" do
      result = described_class.call(samples: [ sample ], weights: { quality: 0.8 })

      # quality 0.8 + cost 0.2 + speed 0.2 = 1.2; renormalized
      expect(result.weights[:quality]).to be_within(1e-4).of(0.8 / 1.2)
      expect(result.weights[:cost]).to be_within(1e-4).of(0.2 / 1.2)
      expect(result.weights[:speed]).to be_within(1e-4).of(0.2 / 1.2)
    end

    it "ignores negative weights and substitutes defaults" do
      result = described_class.call(
        samples: [ sample ],
        weights: { quality: -1.0, cost: 0.5, speed: 0.5 }
      )

      # quality reverts to default 0.6, then renormalize {0.6, 0.5, 0.5} → /1.6
      expect(result.weights[:quality]).to be_within(1e-4).of(0.6 / 1.6)
    end
  end

  describe "project-scoped configuration" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "reads weights from project.fitness_weights when no override is given" do
      project.update!(fitness_weights: { "weights" => { "quality" => 0.8, "cost" => 0.1, "speed" => 0.1 } })

      result = described_class.call(samples: [ sample ], project: project)

      expect(result.weights[:quality]).to be_within(1e-4).of(0.8)
      expect(result.weights[:cost]).to be_within(1e-4).of(0.1)
      expect(result.weights[:speed]).to be_within(1e-4).of(0.1)
    end

    it "lets explicit weights override project settings" do
      project.update!(fitness_weights: { "weights" => { "quality" => 0.8, "cost" => 0.1, "speed" => 0.1 } })

      result = described_class.call(
        samples: [ sample ],
        project: project,
        weights: { quality: 0.5, cost: 0.25, speed: 0.25 }
      )

      expect(result.weights[:quality]).to be_within(1e-4).of(0.5)
    end

    it "reads reference_cost_cents and reference_duration_seconds from project" do
      project.update!(fitness_weights: {
        "reference_cost_cents" => 200,
        "reference_duration_seconds" => 1200
      })

      result = described_class.call(samples: [ sample ], project: project)

      expect(result.reference_cost_cents).to eq(200.0)
      expect(result.reference_duration_seconds).to eq(1200.0)
    end

    it "falls back to defaults when project settings are blank" do
      result = described_class.call(samples: [ sample ], project: project)

      expect(result.weights).to eq(described_class::DEFAULT_WEIGHTS)
      expect(result.reference_cost_cents).to eq(described_class::DEFAULT_REFERENCE_COST_CENTS)
    end

    it "ignores non-positive reference values from project settings" do
      project.update!(fitness_weights: {
        "reference_cost_cents" => 0,
        "reference_duration_seconds" => -10
      })

      result = described_class.call(samples: [ sample ], project: project)

      expect(result.reference_cost_cents).to eq(described_class::DEFAULT_REFERENCE_COST_CENTS)
      expect(result.reference_duration_seconds).to eq(described_class::DEFAULT_REFERENCE_DURATION_SECONDS)
    end
  end

  describe "cross-prompt comparability" do
    it "produces identical scores for two prompts with identical performance regardless of cohort" do
      cohort_a = Array.new(5) { sample(composite_score: 0.9, cost_cents: 100, duration_seconds: 600) }
      cohort_b = Array.new(20) { sample(composite_score: 0.9, cost_cents: 100, duration_seconds: 600) }

      result_a = described_class.call(samples: cohort_a)
      result_b = described_class.call(samples: cohort_b)

      expect(result_a.composite_fitness).to eq(result_b.composite_fitness)
    end

    it "ranks a high-quality prompt above a low-quality one with matching cost and speed" do
      better = described_class.call(samples: [ sample(composite_score: 0.95) ])
      worse = described_class.call(samples: [ sample(composite_score: 0.40) ])

      expect(better.composite_fitness).to be > worse.composite_fitness
    end

    it "ranks a cheap prompt above an expensive one with matching quality and speed" do
      cheap = described_class.call(samples: [ sample(cost_cents: 10) ])
      expensive = described_class.call(samples: [ sample(cost_cents: 1_000) ])

      expect(cheap.composite_fitness).to be > expensive.composite_fitness
    end

    it "ranks a fast prompt above a slow one with matching quality and cost" do
      fast = described_class.call(samples: [ sample(duration_seconds: 60) ])
      slow = described_class.call(samples: [ sample(duration_seconds: 6_000) ])

      expect(fast.composite_fitness).to be > slow.composite_fitness
    end
  end

  describe "integration with sampled run data" do
    let(:project) { create(:project) }
    let(:prompt) { create(:prompt, :global, :with_version) }
    let(:prompt_version) { prompt.current_version }

    it "scores the SampleRuns#collect_sample_data hash shape directly" do
      run = create(:agent_run, :completed,
        project: project,
        prompt_version: prompt_version,
        cost_cents: 50,
        duration_seconds: 300,
        completed_at: 1.day.ago
      )
      create(:quality_metric, :automated, agent_run: run, prompt_version: prompt_version, composite_score: 0.85)

      samples = PromptEvolution::SampleRuns.call(sample_size: 10, days: 7).samples

      result = described_class.call(samples: samples, project: project)

      expect(result.sample_count).to eq(1)
      expect(result.quality_score).to eq(0.85)
      # ref(100) / (cost(50) + ref(100)) ≈ 0.6667
      expect(result.cost_score).to be_within(1e-4).of(100.0 / 150.0)
      # ref(600) / (duration(300) + ref(600)) ≈ 0.6667
      expect(result.speed_score).to be_within(1e-4).of(600.0 / 900.0)
    end
  end
end
