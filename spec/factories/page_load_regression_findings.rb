# frozen_string_literal: true

FactoryBot.define do
  factory :page_load_regression_finding do
    project
    account { project.account }
    pull_request_number { 42 }
    route_name { "dashboard" }
    route_path { "/dashboard" }
    comparison_metric { "lcp_ms" }
    baseline_ms { 640 }
    current_ms { 1100 }
    delta_ms { 460 }
    delta_ratio { 0.72 }
    baseline_commit_sha { "aaa1111" }
    commit_sha { "bbb2222" }
    actionable { true }
    status { "open" }
  end
end
