# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::ScalingDashboardStats do
  describe ".call" do
    let(:project) { create(:project) }

    it "returns a sparse payload when no scaling data exists" do
      stats = described_class.call(project: project)

      expect(stats[:sparse]).to be(true)
      expect(stats[:recommendations]).to eq([])
      expect(stats[:experiments]).to eq([])
    end

    it "surfaces recommendations, threshold review, and recent observations" do
      experiment = create(:scaling_experiment, project: project, name: "Agent Count Scaling", status: "completed")
      create(:scaling_observation, project: project, agent_count_planned: 2, parallelism_observed: 2)
      experiment.update!(cached_summary: cached_summary_payload, summary_samples_key: experiment.samples_key)

      stats = described_class.call(project: project)

      expect_scaling_dashboard_stats(stats, experiment)
    end

    it "keeps GET-style reads read-only when the cached summary is stale" do
      experiment = create(:scaling_experiment, project: project, name: "Stale Cache", status: "completed")
      experiment.update!(
        cached_summary: cached_summary_payload.merge("leading_value" => 99),
        summary_samples_key: "stale-key"
      )

      stats = described_class.call(project: project)

      expect(stats.dig(:experiments, 0, :summary, "leading_value")).to eq(99)
      expect(experiment.reload.cached_summary["leading_value"]).to eq(99)
      expect(experiment.summary_samples_key).to eq("stale-key")
    end

    it "surfaces the measured allocator decision the allocator applies for parallelism experiments" do
      experiment = create(:scaling_experiment, project: project, dimension: "parallelism", status: "completed")
      experiment.update!(
        cached_summary: parallelism_cached_summary_payload,
        summary_samples_key: experiment.samples_key
      )

      stats = described_class.call(project: project)

      measured = parallelism_allocator_decision
      scaling_law_decision = cached_summary_payload.fetch("allocator_decision")
      recommendation = stats.dig(:experiments, 0, :recommendation)
      expect(recommendation).to include(
        "recommended_value" => measured["recommended_value"],
        "confidence" => measured["confidence"],
        "actionable" => true,
        "reason" => measured["reason"]
      )
      expect(recommendation["recommended_value"]).not_to eq(scaling_law_decision["recommended_value"])
    end

    it "counts all observations while limiting the recent observation payload" do
      travel_to Time.zone.parse("2026-07-21 12:00:00 UTC") do
        (Projects::ScalingDashboardStats::RECENT_OBSERVATION_LIMIT + 2).times do |index|
          create(
            :scaling_observation,
            project: project,
            workflow_id: "workflow-#{index}",
            created_at: index.minutes.ago
          )
        end
      end

      stats = described_class.call(project: project)

      expect(stats.dig(:summary, :observation_count)).to eq(Projects::ScalingDashboardStats::RECENT_OBSERVATION_LIMIT + 2)
      expect(stats[:recent_observations].size).to eq(Projects::ScalingDashboardStats::RECENT_OBSERVATION_LIMIT)
      expect(stats[:recent_observations].first.workflow_id).to eq("workflow-0")
      expect(stats[:recent_observations].last.workflow_id).to eq("workflow-14")
    end
  end

  def expect_scaling_dashboard_stats(stats, experiment)
    expect(stats[:sparse]).to be(false)
    expect(stats.dig(:summary, :experiment_count)).to eq(1)
    expect(stats.dig(:summary, :actionable_recommendation_count)).to eq(1)
    expect(stats[:recommendations]).to include(
      hash_including(
        dimension: "agent_count",
        recommended_value: 2,
        confidence: "high",
        actionable: true
      )
    )
    expect(stats[:experiments]).to include(
      hash_including(
        experiment: experiment,
        sample_threshold_review: hash_including("rdr_target_min_samples_per_value" => 30),
        simplifications: include("Uses descriptive confidence intervals.")
      )
    )
    expect(stats[:recent_observations].size).to eq(1)
  end

  def cached_summary_payload
    {
      "dimension" => "agent_count",
      "primary_metric" => "success_rate",
      "sample_count" => 6,
      "leading_value" => 2,
      "sample_threshold_review" => {
        "configured_min_samples_per_value" => 2,
        "analysis_min_samples_per_value" => 2,
        "rdr_target_min_samples_per_value" => 30,
        "meets_rdr_target" => false
      },
      "simplifications" => [ "Uses descriptive confidence intervals." ],
      "allocator_decision" => {
        "recommended_value" => 2,
        "requested_agent_count" => 2,
        "max_batch_size" => 2,
        "sample_count" => 6,
        "confidence" => "high",
        "actionable" => true,
        "reason" => "highest_efficiency_before_threshold",
        "efficiency_gain_vs_control" => 0.2,
        "scaling_exponent" => 0.55,
        "scaling_exponent_confidence_interval" => {
          "estimate" => 0.55,
          "lower_bound" => 0.33,
          "upper_bound" => 0.77,
          "margin_of_error" => 0.22,
          "sample_count" => 6,
          "confidence_level" => 0.95
        }
      },
      "values" => []
    }
  end

  def parallelism_cached_summary_payload
    cached_summary_payload.merge(
      "dimension" => "parallelism",
      "allocator_decision" => parallelism_allocator_decision,
      "scaling_law" => {
        "allocator_decision" => cached_summary_payload.fetch("allocator_decision")
      }
    )
  end

  def parallelism_allocator_decision
    {
      "recommended_value" => 4,
      "parallelism" => 4,
      "max_batch_size" => 4,
      "requested_agent_count" => 4,
      "sample_count" => 12,
      "confidence" => "medium",
      "actionable" => true,
      "reason" => "best_success_rate_before_threshold"
    }
  end
end
