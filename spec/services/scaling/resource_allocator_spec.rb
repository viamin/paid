# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::ResourceAllocator, :no_db do
  let(:default_inputs) { Scaling::AllocationInputs.new(task_count: 4, max_agent_count: 8) }

  def build_observation(agent_count:, success:, created_at: Time.current, **overrides)
    observation_class.new(
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
      metadata: {},
      created_at: created_at
    )
  end

  def measured_return_summary(agent_count: 2, sample_count: 18, reason: "best_success_rate_before_threshold")
    {
      "dimension" => "parallelism",
      "sample_count" => sample_count,
      "parallelism_analysis" => {
        "status" => "ready",
        "sample_count" => sample_count,
        "allocator_decision" => {
          "requested_agent_count" => agent_count,
          "max_batch_size" => agent_count,
          "reason" => reason
        }
      }
    }
  end

  def experiment_value_summary(
    assigned_value:,
    success_rate:,
    avg_duration_seconds:,
    sample_count:,
    avg_agent_count_planned: nil,
    agent_launch_success_rate: nil,
    blocked_task_rate: nil,
    avg_agent_count_launched: nil,
    avg_agent_count_blocked: nil
  )
    {
      "assigned_value" => assigned_value,
      "success_rate" => success_rate,
      "avg_duration_seconds" => avg_duration_seconds,
      "sample_count" => sample_count,
      "avg_agent_count_planned" => avg_agent_count_planned,
      "agent_launch_success_rate" => agent_launch_success_rate,
      "blocked_task_rate" => blocked_task_rate,
      "avg_agent_count_launched" => avg_agent_count_launched,
      "avg_agent_count_blocked" => avg_agent_count_blocked
    }.compact
  end

  def measured_return_experiment_summary(values:, **overrides)
    measured_return_summary.deep_merge(
      {
        "status" => "ready_for_analysis",
        "values" => values
      }.merge(overrides)
    )
  end

  def measured_return_experiment_values
    [
      experiment_value_summary(
        assigned_value: 2,
        success_rate: 0.95,
        avg_duration_seconds: 140,
        sample_count: 9,
        avg_agent_count_planned: 2.0,
        agent_launch_success_rate: 1.0,
        blocked_task_rate: 0.0,
        avg_agent_count_launched: 2.0,
        avg_agent_count_blocked: 0.0
      ),
      experiment_value_summary(
        assigned_value: 4,
        success_rate: 1.0,
        avg_duration_seconds: 120,
        sample_count: 9,
        avg_agent_count_planned: 4.0,
        agent_launch_success_rate: 0.7,
        blocked_task_rate: 0.25,
        avg_agent_count_launched: 2.8,
        avg_agent_count_blocked: 1.0
      )
    ]
  end

  def observation_class
    Struct.new(
      :workflow_id,
      :workflow_name,
      :observation_type,
      :status,
      :success,
      :parallel_execution,
      :task_count,
      :agent_count_planned,
      :agent_count_launched,
      :agent_count_succeeded,
      :agent_count_failed,
      :agent_count_blocked,
      :total_iterations,
      :max_iterations,
      :parallelism_planned,
      :parallelism_observed,
      :batch_count,
      :duration_seconds,
      :total_cost_cents,
      :total_input_tokens,
      :total_output_tokens,
      :metadata,
      :created_at,
      keyword_init: true
    )
  end

  describe ".call" do
    context "with no observations or experiments" do
      it "returns a fallback allocation" do
        result = described_class.call(inputs: default_inputs)

        expect(result.source).to eq(:fallback)
        expect(result.agent_count).to be_positive
        expect(result.max_iterations).to be_positive
        expect(result.reason).to include("insufficient fresh observations")
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

      it "uses experiment guidance when fresh observations are too sparse to score safely" do
        observations = 5.times.map.with_index(1) do |_index, agent_count|
          build_observation(agent_count: agent_count, success: true, duration_seconds: 120 + agent_count)
        end
        summaries = [ measured_return_summary ]

        result = described_class.call(inputs: default_inputs, observations: observations, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("measured returns")
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

    context "with sparse leading cohorts" do
      it "ignores under-supported cohorts when deriving return signals" do
        observations = [
          build_observation(agent_count: 1, success: true, total_cost_cents: 50, duration_seconds: 60),
          *3.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 120, duration_seconds: 120) },
          *3.times.map { build_observation(agent_count: 4, success: true, total_cost_cents: 150, duration_seconds: 90) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("signals=none")
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
      it "prefers measured-return allocator guidance from experiment analysis" do
        summaries = [
          measured_return_experiment_summary(values: measured_return_experiment_values)
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("measured returns recommended agent_count=2")
      end

      it "prefers cached measured-return analysis over mirrored top-level allocator decisions" do
        summaries = [
          measured_return_experiment_summary(
            values: measured_return_experiment_values,
            "allocator_decision" => {
              "requested_agent_count" => 4,
              "max_batch_size" => 4,
              "sample_count" => 9,
              "confidence" => "high"
            }
          )
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("measured returns recommended agent_count=2")
      end

      it "combines agent-count, parallelism, and iteration experiment decisions" do
        result = described_class.call(
          inputs: default_inputs,
          experiment_summaries: experiment_decision_summaries
        )

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(3)
        expect(result.parallelism_level).to eq(2)
        expect(result.max_iterations).to eq(4)
        expect(result.reason).to include("agent_count decision")
        expect(result.reason).to include("parallelism decision")
        expect(result.reason).to include("iteration_count decision")
      end

      it "picks the strongest decision per dimension when duplicates exist" do
        low_confidence = build_experiment_decision_summary("agent_count",
          recommended_value: 9, requested_agent_count: 9,
          sample_count: 6, confidence: "low")
        high_confidence = build_experiment_decision_summary("agent_count",
          recommended_value: 2, requested_agent_count: 2,
          sample_count: 10, confidence: "high")
        parallelism = build_experiment_decision_summary("parallelism",
          recommended_value: 3, requested_agent_count: 2, max_batch_size: 3,
          sample_count: 6, confidence: "medium")

        result = described_class.call(
          inputs: default_inputs,
          experiment_summaries: [ low_confidence, high_confidence, parallelism ]
        )

        expect(result.agent_count).to eq(2)
      end

      it "normalizes string allocator decisions from measured-return analyses" do
        summaries = [
          measured_return_experiment_summary(
            values: measured_return_experiment_values,
            "parallelism_analysis" => {
              "status" => "ready",
              "sample_count" => 18,
              "allocator_decision" => {
                "requested_agent_count" => "2",
                "max_batch_size" => "2",
                "reason" => "best_success_rate_before_threshold"
              }
            }
          )
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.parallelism_level).to eq(2)
      end

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

      it "normalizes string agent-count values from experiment summaries" do
        summaries = [
          { "assigned_value" => "1", "success_rate" => 0.4, "avg_duration_seconds" => 300, "sample_count" => 10 },
          { "assigned_value" => "2", "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => 10 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
      end

      it "normalizes string sample counts from experiment summaries" do
        summaries = [
          { "assigned_value" => 1, "success_rate" => 0.4, "avg_duration_seconds" => 300, "sample_count" => "10" },
          { "assigned_value" => 2, "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => "10" }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
      end

      it "preserves explicit zero durations when ranking experiment leaders" do
        summaries = [
          { assigned_value: 1, success_rate: 0.8, avg_duration_seconds: 10, sample_count: 10 },
          { assigned_value: 2, success_rate: 0.8, avg_duration_seconds: 0, sample_count: 10 }
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

      it "avoids experiment values that show blocked capacity and launch shortfalls" do
        summaries = [
          { assigned_value: 2, success_rate: 0.95, avg_duration_seconds: 140, sample_count: 10, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 0.0 },
          { assigned_value: 4, success_rate: 1.0, avg_duration_seconds: 100, sample_count: 10, agent_launch_success_rate: 0.7, blocked_task_rate: 0.25, avg_agent_count_launched: 2.8, avg_agent_count_blocked: 1.0 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("signals=none")
      end

      it "derives capacity thresholds from planned-versus-launched counts when experiment rates use different denominators" do
        summaries = [
          { assigned_value: 2, success_rate: 0.95, avg_duration_seconds: 140, sample_count: 10, avg_agent_count_planned: 2.0, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 0.0 },
          { assigned_value: 4, success_rate: 1.0, avg_duration_seconds: 100, sample_count: 10, avg_agent_count_planned: 4.0, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 2.0 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("signals=none")
      end

      it "uses planned agent counts instead of assigned values for non-agent-count experiments" do
        summaries = [
          {
            "status" => "ready_for_analysis",
            "dimension" => "parallelism",
            "sample_count" => 20,
            "values" => [
              { "assigned_value" => 2, "success_rate" => 0.95, "avg_duration_seconds" => 140, "sample_count" => 10, "avg_agent_count_planned" => 4.0, "avg_agent_count_launched" => 4.0, "avg_agent_count_blocked" => 0.0 },
              { "assigned_value" => 4, "success_rate" => 1.0, "avg_duration_seconds" => 100, "sample_count" => 10, "avg_agent_count_planned" => 4.0, "avg_agent_count_launched" => 2.0, "avg_agent_count_blocked" => 2.0 }
            ]
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("leading value=2")
        expect(result.reason).to include("signals=none")
      end

      it "falls back to explicit experiment rates when count metrics are absent" do
        summaries = [
          { assigned_value: 2, success_rate: 0.95, avg_duration_seconds: 140, sample_count: 10, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0 },
          { assigned_value: 4, success_rate: 1.0, avg_duration_seconds: 100, sample_count: 10, agent_launch_success_rate: 0.7, blocked_task_rate: 0.25 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("signals=none")
      end

      it "falls back to explicit experiment rates when summarized planned counts are zero" do
        summaries = [
          { assigned_value: 2, success_rate: 0.95, avg_duration_seconds: 140, sample_count: 10, avg_agent_count_planned: 0.0, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 0.0, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0 },
          { assigned_value: 4, success_rate: 1.0, avg_duration_seconds: 100, sample_count: 10, avg_agent_count_planned: 0.0, avg_agent_count_launched: 2.8, avg_agent_count_blocked: 1.0, agent_launch_success_rate: 0.7, blocked_task_rate: 0.25 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("signals=none")
      end

      it "ignores partial count metrics when older experiment summaries only provide explicit rates" do
        summaries = [
          { assigned_value: 2, success_rate: 0.9, avg_duration_seconds: 140, sample_count: 10, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0 },
          { assigned_value: 4, success_rate: 0.95, avg_duration_seconds: 100, sample_count: 20, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0 },
          { assigned_value: 4, success_rate: 0.95, avg_duration_seconds: 100, sample_count: 1, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 2.0 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(4)
        expect(result.reason).to include("leading value=4")
        expect(result.reason).to include("signals=none")
      end

      it "does not dilute explicit threshold signals with older summaries that omit the rate metrics" do
        summaries = [
          { assigned_value: 2, success_rate: 0.9, avg_duration_seconds: 140, sample_count: 10, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0 },
          { assigned_value: 4, success_rate: 0.95, avg_duration_seconds: 100, sample_count: 10, agent_launch_success_rate: 0.7, blocked_task_rate: 0.25 },
          { assigned_value: 4, success_rate: 0.95, avg_duration_seconds: 100, sample_count: 10 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("leading value=2")
        expect(result.reason).to include("signals=none")
      end

      it "weights duplicate experiment summaries by sample count when collapsing a value" do
        summaries = [
          { assigned_value: 2, success_rate: 0.98, avg_duration_seconds: 130, avg_cost_cents: 200, avg_parallelism_observed: 2.0, sample_count: 100, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0, avg_agent_count_launched: 2.0, avg_agent_count_blocked: 0.0 },
          { assigned_value: 2, success_rate: 0.05, avg_duration_seconds: 400, avg_cost_cents: 600, avg_parallelism_observed: 1.0, sample_count: 5, agent_launch_success_rate: 0.5, blocked_task_rate: 0.5, avg_agent_count_launched: 1.0, avg_agent_count_blocked: 1.0 },
          { assigned_value: 4, success_rate: 0.85, avg_duration_seconds: 120, avg_cost_cents: 450, avg_parallelism_observed: 4.0, sample_count: 40, agent_launch_success_rate: 1.0, blocked_task_rate: 0.0, avg_agent_count_launched: 4.0, avg_agent_count_blocked: 0.0 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("leading value=2")
        expect(result.reason).to include("signals=none")
      end

      it "falls back when experiment sample counts are too low" do
        summaries = [
          { assigned_value: 2, success_rate: 0.9, avg_duration_seconds: 100, sample_count: 2 }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "ignores measured-return decisions from experiments still collecting" do
        summaries = [
          {
            "dimension" => "parallelism",
            "status" => "collecting",
            "sample_count" => 18,
            "parallelism_analysis" => {
              "status" => "ready",
              "sample_count" => 18,
              "allocator_decision" => {
                "requested_agent_count" => 6,
                "max_batch_size" => 6,
                "reason" => "best_success_rate_before_threshold"
              }
            }
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "ignores measured-return decisions from sparse parallelism analyses" do
        summaries = [
          {
            "dimension" => "parallelism",
            "sample_count" => 3,
            "parallelism_analysis" => {
              "status" => "ready",
              "sample_count" => 3,
              "allocator_decision" => {
                "requested_agent_count" => 6,
                "max_batch_size" => 6,
                "reason" => "best_success_rate_before_threshold"
              }
            }
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "ignores measured-return decisions whose winning candidate is under-supported" do
        summaries = [
          {
            "dimension" => "parallelism",
            "sample_count" => 12,
            "parallelism_analysis" => {
              "status" => "ready",
              "sample_count" => 12,
              "allocator_decision" => {
                "requested_agent_count" => 6,
                "max_batch_size" => 6,
                "sample_count" => 2,
                "reason" => "best_success_rate_before_threshold"
              }
            }
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "falls back when measured-return decisions use malformed count values" do
        summaries = [
          {
            "dimension" => "parallelism",
            "status" => "ready_for_analysis",
            "sample_count" => 12,
            "parallelism_analysis" => {
              "status" => "ready",
              "sample_count" => "twelve",
              "allocator_decision" => {
                "requested_agent_count" => "many",
                "max_batch_size" => "many",
                "sample_count" => "twelve"
              }
            }
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "falls back when all usable experiment summaries produce an empty grouped hash" do
        summaries = [
          { success_rate: 0.8, avg_duration_seconds: 100, sample_count: 10 }
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

      it "uses allocator decisions from parallelism experiment summaries" do
        summaries = [ parallelism_experiment_summary ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(4)
        expect(result.parallelism_level).to eq(2)
        expect(result.reason).to include("parallelism decision")
      end

      it "uses top-level allocator decisions even when value summaries are too sparse to rank safely" do
        summaries = [
          parallelism_experiment_summary.deep_merge(
            "values" => [
              { "assigned_value" => 2, "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => 2, "avg_cost_cents" => 100.0 }
            ]
          )
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(4)
        expect(result.parallelism_level).to eq(2)
        expect(result.reason).to include("parallelism decision")
      end

      it "normalizes string sample counts in top-level allocator decisions" do
        summaries = [
          parallelism_experiment_summary.deep_merge(
            "sample_count" => "12",
            "allocator_decision" => {
              "requested_agent_count" => "4",
              "max_batch_size" => "2",
              "sample_count" => "6",
              "confidence" => "high"
            }
          )
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(4)
        expect(result.parallelism_level).to eq(2)
        expect(result.reason).to include("parallelism decision")
      end

      it "ignores allocator decisions whose winning candidate is under-supported even when the summary total is sufficient" do
        summaries = [
          parallelism_experiment_summary.deep_merge(
            "sample_count" => 12,
            "allocator_decision" => {
              "requested_agent_count" => 4,
              "parallelism" => 4,
              "max_batch_size" => 4,
              "sample_count" => 2,
              "confidence" => "high"
            },
            "values" => [
              { "assigned_value" => 2, "success_rate" => 0.8, "avg_duration_seconds" => 150, "sample_count" => 10, "avg_cost_cents" => 100.0 }
            ]
          )
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.parallelism_level).to eq(2)
        expect(result.reason).to include("experiment leading value=2")
      end

      it "ignores allocator decisions from non-parallelism dimensions" do
        summaries = [
          {
            "status" => "ready_for_analysis",
            "dimension" => "iteration_count",
            "sample_count" => 12,
            "allocator_decision" => {
              "requested_agent_count" => 8,
              "max_batch_size" => 8,
              "confidence" => "high"
            },
            "values" => [
              { "assigned_value" => 3, "success_rate" => 0.9, "avg_duration_seconds" => 200, "sample_count" => 6, "avg_cost_cents" => 100.0 },
              { "assigned_value" => 5, "success_rate" => 0.8, "avg_duration_seconds" => 250, "sample_count" => 6, "avg_cost_cents" => 110.0 }
            ]
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).not_to eq(8)
        expect(result.reason).not_to include("allocator decision")
      end

      it "ignores measured-return decisions from non-parallelism dimensions even when parallelism analysis is cached" do
        result = described_class.call(
          inputs: default_inputs,
          experiment_summaries: [ non_parallelism_summary_with_cached_parallelism_analysis ]
        )

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).not_to eq(8)
        expect(result.reason).not_to include("measured returns")
        expect(result.reason).not_to include("allocator decision")
      end

      it "ignores malformed experiment value identifiers and falls back safely" do
        summaries = [
          {
            "status" => "ready_for_analysis",
            "values" => [
              { "assigned_value" => "two", "success_rate" => 0.95, "avg_duration_seconds" => 140, "sample_count" => 10 },
              { "assigned_value" => "four", "success_rate" => 1.0, "avg_duration_seconds" => 100, "sample_count" => 10 }
            ]
          }
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:fallback)
      end

      it "ignores allocator decisions from summaries that are not ready_for_analysis" do
        summaries = [
          parallelism_experiment_summary.merge("status" => "collecting"),
          experiment_summary(value: 2, success_rate: 0.8, avg_duration_seconds: 150, sample_count: 10, avg_cost_cents: 100.0)
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).not_to include("allocator decision")
      end

      it "ignores grouped experiment values from summaries that are still collecting" do
        summaries = [
          parallelism_experiment_summary.merge(
            "status" => "collecting",
            "values" => [
              { "assigned_value" => 4, "success_rate" => 1.0, "avg_duration_seconds" => 100, "sample_count" => 10, "avg_cost_cents" => 100.0 }
            ]
          ),
          experiment_summary(value: 2, success_rate: 0.8, avg_duration_seconds: 150, sample_count: 10, avg_cost_cents: 100.0)
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.reason).to include("experiment leading value=2")
      end

      it "ignores allocator decisions that do not meet the minimum sample threshold" do
        summaries = [
          low_confidence_parallelism_summary,
          experiment_summary(value: 2, success_rate: 0.8, avg_duration_seconds: 150, sample_count: 10, avg_cost_cents: 100.0)
        ]

        result = described_class.call(inputs: default_inputs, experiment_summaries: summaries)

        expect(result.source).to eq(:experiment)
        expect(result.agent_count).to eq(2)
        expect(result.parallelism_level).to eq(2)
        expect(result.reason).to include("experiment leading value=2")
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

      it "ignores stale observation costs when applying the budget cap" do
        inputs = Scaling::AllocationInputs.new(task_count: 4, max_agent_count: 8, budget_cents: 50)
        observations = 6.times.map do
          build_observation(
            agent_count: 2,
            success: true,
            total_cost_cents: 200,
            duration_seconds: 120,
            created_at: 10.days.ago
          )
        end

        result = described_class.call(inputs: inputs, observations: observations)

        expect(result.source).to eq(:fallback)
        expect(result.agent_count).to eq(2)
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

    context "with observations where planned differs from launched" do
      def build_partial_launch_observation(planned:, launched:)
        build_observation(agent_count: planned, success: true, total_cost_cents: 300, duration_seconds: 100).tap do |obs|
          obs.agent_count_launched = launched
          obs.agent_count_blocked = planned - launched
        end
      end

      it "groups by agent_count_planned so partial launches are attributed correctly" do
        observations = [
          *3.times.map { build_partial_launch_observation(planned: 4, launched: 3) },
          *3.times.map { build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120) }
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.reason).not_to include("agent_count=3")
      end

      it "falls back to launched counts when older observations do not record planned counts" do
        observations = [
          *3.times.map do
            build_observation(agent_count: 2, success: true, total_cost_cents: 100, duration_seconds: 120).tap do |obs|
              obs.agent_count_planned = 0
            end
          end,
          *3.times.map do
            build_observation(agent_count: 4, success: false, total_cost_cents: 300, duration_seconds: 180).tap do |obs|
              obs.agent_count_planned = 0
            end
          end
        ]

        result = described_class.call(inputs: default_inputs, observations: observations)

        expect(result.source).to eq(:observations)
        expect(result.agent_count).to eq(2)
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

  def parallelism_experiment_summary
    {
      "status" => "ready_for_analysis",
      "dimension" => "parallelism",
      "sample_count" => 12,
      "allocator_decision" => {
        "requested_agent_count" => 4,
        "parallelism" => 2,
        "max_batch_size" => 2,
        "sample_count" => 6,
        "confidence" => "high"
      },
      "values" => [
        { "assigned_value" => 1, "success_rate" => 1.0, "avg_duration_seconds" => 300, "sample_count" => 6, "avg_cost_cents" => 120.0 },
        { "assigned_value" => 2, "success_rate" => 1.0, "avg_duration_seconds" => 200, "sample_count" => 6, "avg_cost_cents" => 125.0 }
      ]
    }
  end

  def low_confidence_parallelism_summary
    parallelism_experiment_summary.merge(
      "sample_count" => 2,
      "allocator_decision" => parallelism_experiment_summary.fetch("allocator_decision").merge(
        "requested_agent_count" => 4,
        "parallelism" => 4,
        "max_batch_size" => 4,
        "sample_count" => 2
      )
    )
  end

  def non_parallelism_summary_with_cached_parallelism_analysis
    {
      "status" => "ready_for_analysis",
      "dimension" => "iteration_count",
      "sample_count" => 12,
      "allocator_decision" => {
        "requested_agent_count" => 8,
        "max_batch_size" => 8,
        "confidence" => "high"
      },
      "parallelism_analysis" => {
        "status" => "ready",
        "sample_count" => 12,
        "allocator_decision" => {
          "requested_agent_count" => 8,
          "max_batch_size" => 8,
          "reason" => "best_success_rate_before_threshold"
        }
      },
      "values" => [
        { "assigned_value" => 3, "success_rate" => 0.9, "avg_duration_seconds" => 200, "sample_count" => 6, "avg_cost_cents" => 100.0 },
        { "assigned_value" => 5, "success_rate" => 0.8, "avg_duration_seconds" => 250, "sample_count" => 6, "avg_cost_cents" => 110.0 }
      ]
    }
  end

  def experiment_summary(value:, **attributes)
    {
      "status" => "ready_for_analysis",
      "dimension" => "agent_count",
      "values" => [
        { "assigned_value" => value }.merge(attributes.transform_keys(&:to_s))
      ]
    }
  end

  def experiment_decision_summaries
    [
      build_experiment_decision_summary("agent_count",
        recommended_value: 3,
        requested_agent_count: 3,
        sample_count: 6,
        confidence: "high"),
      build_experiment_decision_summary("parallelism",
        recommended_value: 2,
        requested_agent_count: 3,
        max_batch_size: 2,
        sample_count: 6,
        confidence: "high"),
      build_experiment_decision_summary("iteration_count",
        recommended_value: 4,
        requested_iteration_count: 4,
        max_iterations: 4,
        sample_count: 6,
        confidence: "medium")
    ]
  end

  def build_experiment_decision_summary(dimension, **decision)
    {
      dimension: dimension,
      status: "ready_for_analysis",
      allocator_decision: decision
    }
  end
end
