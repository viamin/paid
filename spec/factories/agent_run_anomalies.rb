# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_anomaly do
    transient do
      anomaly_project { nil }
    end

    project { anomaly_project || association(:project) }
    agent_run { association :agent_run, :completed, :with_metrics, project: project }
    anomaly_type { "high_value" }
    severity { "warning" }
    metric_name { "tokens_total" }
    metric_value { 35000.0 }
    baseline_mean { 15000.0 }
    baseline_standard_deviation { 5000.0 }
    deviation_factor { 4.0 }
    message { "Warning: tokens_total (35000.0) is 4.0 standard deviations above the baseline" }

    after(:build) do |agent_run_anomaly, evaluator|
      next if evaluator.anomaly_project

      agent_run_anomaly.project = agent_run_anomaly.agent_run.project if agent_run_anomaly.agent_run
    end
  end
end
