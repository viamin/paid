# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_anomaly do
    agent_run { association :agent_run, :completed, :with_metrics, project: project }
    project
    anomaly_type { "high_value" }
    severity { "warning" }
    metric_name { "tokens_total" }
    metric_value { 35000.0 }
    baseline_mean { 15000.0 }
    baseline_standard_deviation { 5000.0 }
    deviation_factor { 4.0 }
    message { "Warning: tokens_total (35000.0) is 4.0 standard deviations above the baseline" }
  end
end
