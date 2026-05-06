# frozen_string_literal: true

module PerformanceBenchmarks
  class Configuration
    DEFAULTS = {
      "container_startup_time" => {
        "name" => "Container startup time",
        "description" => "Completed provision_container phase duration for recent agent runs.",
        "budget_ms" => 30_000,
        "regression_threshold" => 1.25
      },
      "workflow_latency" => {
        "name" => "Workflow latency",
        "description" => "Wall-clock time from agent run creation to completion.",
        "budget_ms" => 3_600_000,
        "regression_threshold" => 1.2
      },
      "dashboard_load_time" => {
        "name" => "Dashboard load time",
        "description" => "Service-layer time to compute the main dashboard payload.",
        "budget_ms" => 3_000,
        "regression_threshold" => 1.5
      },
      "search_latency" => {
        "name" => "Search latency",
        "description" => "Knowledge search service latency using exact search by default.",
        "budget_ms" => 2_000,
        "regression_threshold" => 1.5
      },
      "pool_utilization" => {
        "name" => "Pool utilization",
        "description" => "Container pool hit rate as a percentage of total provisions.",
        "budget_ms" => 100,
        "regression_threshold" => 0.8
      },
      "query_performance" => {
        "name" => "Query performance",
        "description" => "Agent run phase duration measuring overall system throughput.",
        "budget_ms" => 60_000,
        "regression_threshold" => 1.3
      }
    }.freeze

    def self.metric(key)
      DEFAULTS.fetch(key)
    end

    def self.metrics
      DEFAULTS
    end
  end
end
