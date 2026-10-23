# frozen_string_literal: true

module ProjectDashboardMetrics
  class Snapshot
    CACHE_TTL = 2.days
    CACHE_NAMESPACE = "project_dashboard_metrics".freeze

    def self.fetch(...) = new(...).fetch
    def self.refresh(...) = new(...).refresh

    def initialize(project:)
      @project = project
    end

    # @spec PROJECT-DASHBOARD-METRICS-002
    def fetch
      Rails.cache.read(cache_key)
    end

    # @spec PROJECT-DASHBOARD-METRICS-002, PROJECT-DASHBOARD-METRICS-003
    def refresh
      snapshot = {
        average_merge_seconds: average_merge_seconds,
        average_ci_seconds: average_ci_seconds,
        average_tokens_per_pr: average_tokens_per_pr,
        calculated_on: Time.zone.today
      }
      Rails.cache.write(cache_key, snapshot, expires_in: CACHE_TTL)
      snapshot
    end

    private

    attr_reader :project

    def cache_key
      [ CACHE_NAMESPACE, project.id ].join("/")
    end

    def average_merge_seconds
      value = merged_pull_requests.pick(Arel.sql("AVG(EXTRACT(EPOCH FROM (github_updated_at - github_created_at)))"))
      value&.to_f&.round
    end

    def merged_pull_requests
      project.issues.pull_requests_only.where(pr_review_phase: "merged")
    end

    def average_ci_seconds
      value = completed_pipelines
        .where("jsonb_typeof(normalized_data -> 'duration_seconds') = 'number'")
        .average(Arel.sql("(normalized_data ->> 'duration_seconds')::numeric"))
      value&.to_f&.round
    end

    def completed_pipelines
      project.external_connector_events.processed.by_event_type("pipeline_completed")
    end

    def average_tokens_per_pr
      value = ActiveRecord::Base.connection.select_value(average_tokens_per_pr_sql)
      value&.to_f&.round
    end

    def average_tokens_per_pr_sql
      ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, project.id ])
        SELECT AVG(tokens)
        FROM (
          SELECT SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)) AS tokens
          FROM agent_runs
          WHERE project_id = ?
            AND goal = 'create_pr'
            AND status = 'completed'
            AND synthetic = FALSE
            AND pull_request_number IS NOT NULL
          GROUP BY pull_request_number
        ) AS per_pull_request
      SQL
    end
  end
end
