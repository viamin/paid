# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationExperiments::Analyze do
  let(:configuration_experiment) { create(:configuration_experiment, status: "running", min_samples_per_variant: 5) }
  let!(:control) do
    create(:configuration_experiment_variant,
      configuration_experiment: configuration_experiment,
      config_value: configuration_experiment.control_value,
      is_control: true)
  end
  let!(:variant) { create(:configuration_experiment_variant, configuration_experiment: configuration_experiment, config_value: JSON.generate(6000)) }
  let(:project) { create(:project) }

  def add_scores(test_variant, scores)
    timestamp = Time.current
    agent_run_rows = scores.map do
      {
        project_id: project.id,
        agent_type: "claude_code",
        status: "pending",
        goal: "create_pr",
        trigger_type: "automatic",
        custom_prompt: "configuration experiment sample",
        proxy_token: SecureRandom.hex(32),
        created_at: timestamp,
        updated_at: timestamp
      }
    end

    inserted_runs = AgentRun.insert_all!(agent_run_rows, returning: %w[id])
    assignment_rows = scores.zip(inserted_runs.rows.flatten).map do |score, agent_run_id|
      {
        configuration_experiment_id: configuration_experiment.id,
        configuration_experiment_variant_id: test_variant.id,
        agent_run_id: agent_run_id,
        quality_score: score,
        created_at: timestamp,
        updated_at: timestamp
      }
    end

    ConfigurationExperimentAssignment.insert_all!(assignment_rows)
    test_variant.update!(sample_count: scores.size)
  end

  it "detects a significantly better variant" do
    add_scores(control, [ 0.3, 0.35, 0.25, 0.3, 0.28, 0.32, 0.27, 0.31, 0.29, 0.33 ])
    add_scores(variant, [ 0.8, 0.85, 0.9, 0.82, 0.88, 0.84, 0.86, 0.83, 0.87, 0.81 ])

    result = described_class.call(configuration_experiment: configuration_experiment)

    expect(result.status).to eq(:winner_found)
    expect(result.winner).to eq(variant)
  end

  it "returns insufficient data below the minimum sample count" do
    add_scores(control, [ 0.5, 0.6 ])
    add_scores(variant, [ 0.7, 0.8 ])

    result = described_class.call(configuration_experiment: configuration_experiment)

    expect(result.status).to eq(:insufficient_data)
  end
end
