# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::ResourceAllocator do
  let(:default_inputs) { Scaling::AllocationInputs.new(task_count: 4, max_agent_count: 8) }

  def build_observation(agent_count:, success:, created_at: Time.current, **overrides)
    ScalingObservation.new(
      project: build(:project),
      workflow_id: SecureRandom.uuid,
      workflow_name: "TestWorkflow",
      observation_type: "feature_orchestration",
      status: "completed",
      success: success,
      parallel_execution: true,
      task_count: 4,
      agent_count_planned: agent_count,
      agent_count_launched: agent_count,
      agent_count_succeeded: success ? agent_count : 0,
      agent_count_failed: success ? 0 : agent_count,
      agent_count_blocked: 0,
      total_iterations: overrides.fetch(:total_iterations, 3),
      max_iterations: 2,
      parallelism_planned: agent_count,
      parallelism_observed: overrides.fetch(:parallelism_observed, agent_count),
      batch_count: agent_count,
      duration_seconds: overrides.fetch(:duration_seconds, 120),
      total_cost_cents: overrides.fetch(:total_cost_cents, 100 * agent_count),
      total_input_tokens: 500,
      total_output_tokens: 200,
      metadata: {}
    ) do |obs|
      obs.created_at = created_at
    end
  end

  describe ".call" do
    context "with no observations or experiments" do
      it "returns a fallback allocation" do
        result = described_class.call(inputs: default_inputs)

        expect(result.source).to eq(:fallback)
        expect(result.agent_count).to be_positive
        expect(result.max_iterations).to be_positive
        expect(result.reason).to include("insufficient observations")
      end

      it "clamps agent count to task_count as a safe default" do
        inputs = Scaling::AllocationInputs.new(task_count: 3, max_agent_count: 8)
        result = described_class.call(inputs: inputs)

        expect(result.agent_count).to be <= 3
      end

      it "caps fallback parallelism by max parallelism width" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 4,
          max_agent_count: 8,
          parallelizable_group_count: 1,
          max_parallelism: 4
        )

        result = described_class.call(inputs: inputs)

        expect(result.parallelism_level).to eq(2)
      end
    end

    context "with too few observations" do
      it "returns fallback when below minimum observation threshold" do
        observations = 4.times.map do
          build_observation(agent_count: 2, success: true)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)
        expect(result.source).to eq(:fallback)
      end
    end

    context "with stale observations" do
      it "returns fallback when all observations are older than threshold" do
        observations = 6.times.map do
          build_observation(
            agent_count: 2,
            success: true,
            created_at: 10.days.ago
          )
        end

        result = described_class.call(inputs: default_inputs, observations: observations)
        expect(result.source).to eq(:fallback)
      end

      it "excludes stale observations from scoring even when fresh ones exist" do
        stale_high_count = 4.times.map do
          build_observation(agent_count: 4, success: true, total_cost_cents: 100, duration_seconds: 80, created_at: 10.days.ago)
        end
        fresh_low_count = 6.times.map do
          build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120)
        end

        result = described_class.call(inputs: default_inputs, observations: stale_high_count + fresh_low_count)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(2)
      end
    end

    context "with fresh sufficient observations showing clear winner" do
      it "allocates based on the best-performing agent count" do
        observations = [
          *3.times.map { build_observation(agent_count: 1, success: false, total_cost_cents: 50, duration_seconds: 200) },
          *3.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 200, duration_seconds: 200) },
          *3.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 150, duration_seconds: 80) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(4)
        expect(result.reason).to include("agent_count=4")
      end
    end

    context "with observations showing diminishing returns" do
      it "penalizes agent counts beyond diminishing returns threshold" do
        observations = [
          *3.times.map { build_observation(agent_count: 1, success: false, total_cost_cents: 50, duration_seconds: 300) },
          *3.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 150) },
          *3.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 400, duration_seconds: 140) },
          *3.times.map { build_observation(agent_count: 8, success: true, total_cost_cents: 800, duration_seconds: 130) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to be <= 4
      end
    end

    context "with observations where higher agent counts fail" do
      it "prefers lower agent counts when they succeed more" do
        observations = [
          *4.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120) },
          *4.times.map { build_observation(agent_count: 4, success: false, total_cost_cents: 300, duration_seconds: 180) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(2)
      end
    end

    context "with experiment summaries but no observations" do
      it "allocates based on the experiment's leading value" do
        summaries = [
          { assigned_value: 1, success_rate: 0.4, avg_duration_seconds: 300, sample_count: 10 },
          { assigned_value: 2, success_rate: 0.8, avg_duration_seconds: 150, sample_count: 10 },
          { assigned_value: 4, success_rate: 0.6, avg_duration_seconds: 120, sample_count: 10 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("experiment leading value=2")
      end

      it "supports string-keyed experiment summaries" do
        summaries = [
          { "assigned_value" => 1, "success_rate" => 0.4, "avg_duration_seconds" => 300, "sample_count" => 10 },
          { "assigned_value" => 2, "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => 10 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
      end

      it "caps experiment parallelism by max parallelism width" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 4,
          max_agent_count: 8,
          parallelizable_group_count: 1,
          max_parallelism: 4
        )
        summaries = [
          { assigned_value: 4, success_rate: 0.8, avg_duration_seconds: 150, sample_count: 10 }
        ]

        result = described_class.call(inputs: inputs, experiment_summaries: summaries)

        expect(result.parallelism_level).to eq(4)
      end

      it "ignores unusable experiment cohorts when selecting the leader" do
        summaries = [
          { assigned_value: 1, success_rate: 0.31, avg_duration_seconds: 300, sample_count: 10 },
          { assigned_value: 2, success_rate: 1.0, avg_duration_seconds: 100, sample_count: 1 },
          { assigned_value: 3, success_rate: 0.9, avg_duration_seconds: 90, sample_count: 2 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(1)
      end

      it "falls back when experiment sample counts are too low" do
        summaries = [
          { assigned_value: 2, success_rate: 0.9, avg_duration_seconds: 100, sample_count: 2 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end
    end

    context "with nested cached_summary format from SummarizeResults" do
      it "extracts per-value data from the values array" do
        summaries = [
          {
            "status" => "ready_for_analysis",
            "dimension" => "agent_count",
            "sample_count" => 20,
            "values" => [
              { "assigned_value" => 1, "success_rate" => 0.4, "avg_duration_seconds" => 300, "sample_count" => 10, "avg_cost_cents" => 50.0 },
              { "assigned_value" => 2, "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => 10, "avg_cost_cents" => 100.0 }
            ]
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
      end
    end

    context "with experiment-based budget constraint" do
      it "caps agent count using experiment avg_cost_cents when no observations exist" do
        inputs = Scaling::AllocationInputs.new(task_count: 8, max_agent_count: 8, budget_cents: 150)
        summaries = [
          { assigned_value: 4, success_rate: 0.8, avg_duration_seconds: 100, sample_count: 10, avg_cost_cents: 100.0 }
        ]

        result = described_class.call(inputs: inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(1)
      end
    end

    context "with experiment summaries where success rate is very low" do
      it "falls back when no experiment summary meets minimum success rate" do
        summaries = [
          { assigned_value: 2, success_rate: 0.1, avg_duration_seconds: 300, sample_count: 10 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end
    end

    context "when both observations and experiments are available" do
      it "uses observations when both sources are available and sufficient" do
        observations = 6.times.map do
          build_observation(agent_count: 3, success: true, total_cost_cents: 150, duration_seconds: 100)
        end
        summaries = [
          { assigned_value: 1, success_rate: 0.9, avg_duration_seconds: 80, sample_count: 20 }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations, experiment_summaries: summaries)

        expect(result.source).to eq(:observations)
      end
    end

    context "with budget constraint" do
      it "caps agent count to what the budget allows based on observed costs" do
        inputs = Scaling::AllocationInputs.new(task_count: 8, max_agent_count: 8, budget_cents: 300)
        observations = [
          *4.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120) },
          *4.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 500, duration_seconds: 80) }
        ]

        result = described_class.call(inputs: inputs, observations: observations)

        avg_cost_per_agent = observations.sum(&:total_cost_cents).to_f /
                             observations.sum { |obs| obs.agent_count_launched.to_i }
        max_affordable = (300 / avg_cost_per_agent).floor
        expect(result.agent_count).to be <= [ max_affordable, 4 ].min
      end

      it "applies budget cap to fallback allocation" do
        inputs = Scaling::AllocationInputs.new(task_count: 4, max_agent_count: 8, budget_cents: 50)
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, total_cost_cents: 200, duration_seconds: 120)
        end

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.agent_count).to eq(1)
      end

      it "never returns zero agents when the budget is below observed per-agent cost" do
        inputs = Scaling::AllocationInputs.new(task_count: 8, max_agent_count: 8, budget_cents: 10)
        observations = [
          *4.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120) },
          *4.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 200, duration_seconds: 80) }
        ]

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.agent_count).to eq(1)
      end
    end

    context "with max_agent_count constraint" do
      it "never exceeds max_agent_count even if observations suggest higher" do
        inputs = Scaling::AllocationInputs.new(task_count: 8, max_agent_count: 2)
        observations = [
          *4.times.map { build_observation(agent_count: 1, success: false, total_cost_cents: 50, duration_seconds: 300) },
          *4.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 200, duration_seconds: 80) }
        ]

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.agent_count).to be <= 2
      end
    end

    context "with allocation struct" do
      it "includes metrics about the decision context" do
        result = described_class.call(inputs: default_inputs)

        expect(result.metrics).to include(
          observation_count: be_a(Integer),
          experiment_summary_count: be_a(Integer),
          task_count: 4,
          complexity_score: be_a(Float),
          parallelism_potential: be_a(Float)
        )
      end
    end

    context "with iteration recommendation" do
      it "recommends iterations based on observed average" do
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, total_iterations: 5, duration_seconds: 120)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.max_iterations).to eq(5)
      end

      it "clamps iterations to minimum of 1" do
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, total_iterations: 0, duration_seconds: 120)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.max_iterations).to be >= 1
      end

      it "clamps iterations to maximum of 10" do
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, total_iterations: 50, duration_seconds: 120)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.max_iterations).to be <= 10
      end
    end

    context "with parallelism recommendation" do
      it "limits parallelism to configured max parallelism width" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 6,
          max_agent_count: 8,
          parallelizable_group_count: 2,
          max_parallelism: 2
        )
        observations = 6.times.map do
          build_observation(
            agent_count: 4,
            success: true,
            parallelism_observed: 4,
            duration_seconds: 120
          )
        end

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.parallelism_level).to be <= 2
      end

      it "limits parallelism to agent count" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 4,
          max_agent_count: 2,
          max_parallelism: 4
        )
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, parallelism_observed: 2, duration_seconds: 120)
        end

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.parallelism_level).to be <= 2
      end

      it "caps observed parallelism after clamping the chosen agent count" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 8,
          max_agent_count: 2,
          max_parallelism: 8
        )
        observations = [
          *4.times.map { build_observation(agent_count: 1, success: false, total_cost_cents: 50, duration_seconds: 300) },
          *4.times.map { build_observation(agent_count: 4, success: true, parallelism_observed: 4, total_cost_cents: 200, duration_seconds: 80) }
        ]

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.agent_count).to eq(2)
        expect(result.parallelism_level).to eq(2)
      end

      it "uses max parallelism width instead of parallel group count" do
        inputs = Scaling::AllocationInputs.new(
          task_count: 4,
          max_agent_count: 8,
          parallelizable_group_count: 1,
          max_parallelism: 4
        )
        observations = 6.times.map do
          build_observation(agent_count: 4, success: true, parallelism_observed: 4, duration_seconds: 120)
        end

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.parallelism_level).to eq(4)
      end

      it "treats nil durations as zero when averaging observation cohorts" do
        observations = [
          *3.times.map { build_observation(agent_count: 2, success: true, duration_seconds: nil) },
          *3.times.map { build_observation(agent_count: 2, success: true, duration_seconds: 120) }
        ]

        expect { described_class.call(inputs: default_inputs, observations: observations) }.not_to raise_error
      end
    end

    context "with mixed success rates across agent counts" do
      it "selects the agent count with the best composite score" do
        observations = [
          *3.times.map { build_observation(agent_count: 1, success: true, total_cost_cents: 50, duration_seconds: 200) },
          *3.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120) },
          *3.times.map { build_observation(agent_count: 3, success: true, total_cost_cents: 150, duration_seconds: 110) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to be_between(1, 4)
      end
    end

    context "with single observation group" do
      it "picks the only available agent count" do
        observations = 6.times.map do
          build_observation(agent_count: 3, success: true, total_cost_cents: 150, duration_seconds: 100)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.agent_count).to eq(3)
      end
    end

    context "with observations having zero cost" do
      it "still produces a valid allocation" do
        observations = 6.times.map do
          build_observation(agent_count: 2, success: true, total_cost_cents: 0, duration_seconds: 100)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to be_positive
      end
    end

    context "when all observations fail" do
      it "still allocates based on cost/duration efficiency" do
        observations = [
          *3.times.map { build_observation(agent_count: 1, success: false, total_cost_cents: 50, duration_seconds: 100) },
          *3.times.map { build_observation(agent_count: 4, success: false, total_cost_cents: 400, duration_seconds: 300) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(1)
      end
    end

    context "with only one agent count group in observations" do
      it "picks the single available value" do
        observations = Array.new(6) do
          build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120)
        end

        result = described_class.call(inputs: default_inputs, observations: observations)
        expect(result.agent_count).to eq(2)
      end
    end
  end
end
