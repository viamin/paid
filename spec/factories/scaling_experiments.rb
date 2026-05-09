# frozen_string_literal: true

FactoryBot.define do
  factory :scaling_experiment do
    project
    sequence(:name) { |n| "Scaling Experiment #{n}" }
    hypothesis { "Success improves as agent count increases before diminishing returns appear." }
    dimension { "agent_count" }
    values_tested { [ 1, 2, 4 ] }
    control_value { 1 }
    context_filter { { "min_task_count" => 2 } }
    status { "running" }
    min_samples_per_value { 2 }
    traffic_percentage { 100 }
  end
end
