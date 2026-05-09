# frozen_string_literal: true

module ScalingObservations
  class Record
    NON_LAUNCHED_ERRORS = %w[dependencies_failed unresolvable_dependencies].freeze
    TERMINAL_STATUS_ERRORS = %w[deadline_exceeded no_capacity cancelled_by_policy unresolvable_dependencies].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project_id:, workflow_id:, workflow_name:, issue_id: nil, tasks: [], parallel_result: nil,
      started_at: nil, error_details: {}, metadata: {})
      @project_id = project_id
      @workflow_id = workflow_id
      @workflow_name = workflow_name
      @issue_id = issue_id
      @tasks = Array(tasks).map(&:deep_symbolize_keys)
      @parallel_result = (parallel_result || {}).deep_symbolize_keys
      @started_at = started_at
      @error_details = normalize_hash(error_details)
      @metadata = normalize_hash(metadata)
    end

    def call
      observation = ScalingObservation.find_or_initialize_by(project_id: project_id, workflow_id: workflow_id)

      observation.assign_attributes(
        issue_id: issue_id,
        workflow_name: workflow_name,
        observation_type: "feature_orchestration",
        status: observation_status,
        success: observation_success?,
        parallel_execution: parallel_execution?,
        task_count: tasks.size,
        dependency_edge_count: dependency_edge_count,
        parallelizable_group_count: parallelizable_group_count,
        agent_count_planned: tasks.size,
        agent_count_launched: launched_count,
        agent_count_succeeded: succeeded_count,
        agent_count_failed: failed_count,
        agent_count_blocked: blocked_count,
        total_iterations: child_runs.sum { |run| run.iterations.to_i },
        max_iterations: child_runs.map { |run| run.iterations.to_i }.max.to_i,
        parallelism_planned: parallelism_planned,
        parallelism_observed: parallelism_observed,
        batch_count: batch_count,
        duration_seconds: duration_seconds,
        total_cost_cents: child_runs.sum { |run| run.cost_cents.to_i },
        total_input_tokens: child_runs.sum { |run| run.tokens_input.to_i },
        total_output_tokens: child_runs.sum { |run| run.tokens_output.to_i },
        metadata: observation_metadata
      )

      observation.save!
      observation
    end

    private

    attr_reader :project_id, :workflow_id, :workflow_name, :issue_id, :tasks, :parallel_result, :started_at,
      :error_details, :metadata

    def project
      @project ||= Project.find(project_id)
    end

    def child_runs
      @child_runs ||= AgentRun.where(project: project, parent_workflow_id: workflow_id).to_a
    end

    def execution_summary
      @execution_summary ||= normalize_hash(parallel_result[:execution_summary]).deep_symbolize_keys
    end

    def result_rows
      @result_rows ||= Array(parallel_result[:results]).map do |result|
        result.is_a?(Hash) ? result.deep_symbolize_keys : {}
      end
    end

    def dependency_edge_count
      tasks.sum { |task| Array(task[:dependencies]).size }
    end

    def parallelizable_group_count
      tasks.group_by { |task| task[:parallel_group] }.count { |_group, grouped_tasks| grouped_tasks.size > 1 }
    end

    def parallelism_planned
      tasks.group_by { |task| task[:parallel_group] }.values.map(&:size).max.to_i
    end

    def parallelism_observed
      execution_summary[:max_parallelism_observed].to_i
    end

    def batch_count
      execution_summary[:batch_count].to_i
    end

    def launched_count
      return launched_results.size if result_rows.any?

      child_runs.size
    end

    def succeeded_count
      return successful_results.size if result_rows.any?

      child_run_status_counts.fetch("completed", 0)
    end

    def failed_count
      return launched_failed_results.size if result_rows.any?

      AgentRun::FAILURE_STATUSES.sum { |status| child_run_status_counts.fetch(status, 0) }
    end

    def blocked_count
      return blocked_results.size if result_rows.any?

      return 0 unless parallel_execution?

      [ tasks.size - launched_count, 0 ].max
    end

    def child_run_status_counts
      @child_run_status_counts ||= child_runs.group_by(&:status).transform_values(&:size)
    end

    def launched_results
      result_rows.reject do |result|
        result[:queued] == true || result.key?(:blocked_by) || NON_LAUNCHED_ERRORS.include?(result[:error].to_s)
      end
    end

    def successful_results
      result_rows.select { |result| result[:success] }
    end

    def terminal_failed_results
      result_rows.select { |result| result[:success] == false }
    end

    def launched_failed_results
      terminal_failed_results - blocked_results
    end

    def blocked_results
      result_rows.select do |result|
        result[:queued] == true || result.key?(:blocked_by) || NON_LAUNCHED_ERRORS.include?(result[:error].to_s)
      end
    end

    def duration_seconds
      return unless started_at

      [ Time.current - started_at, 0 ].max.to_i
    end

    def observation_status
      return "failed" if error_details.present?
      return "skipped" unless parallel_execution?
      return parallel_result[:error].to_s if parallel_result[:error].present?
      return terminal_status_from_results if terminal_status_from_results
      return "completed" if parallel_result[:success]
      return "partial_failure" if succeeded_count.positive? && failed_count.positive?

      "failed"
    end

    def observation_success?
      return false if error_details.present?
      return true unless parallel_execution?

      parallel_result[:success] == true
    end

    def parallel_execution?
      tasks.size > 1
    end

    def terminal_status_from_results
      terminal_errors = result_rows.filter_map { |result| result[:error].presence }.uniq

      TERMINAL_STATUS_ERRORS.find { |error| terminal_errors.include?(error) }
    end

    def observation_metadata
      metadata.merge(
        "batch_sizes" => Array(execution_summary[:batch_sizes]),
        "error_tally" => result_rows.filter_map { |result| result[:error].presence }.tally,
        "child_agent_run_ids" => child_runs.map(&:id),
        "parallel_result" => {
          "completed" => parallel_result[:completed],
          "failed" => parallel_result[:failed],
          "total" => parallel_result[:total],
          "error" => parallel_result[:error]
        }.compact,
        "conflicts" => normalize_hash(parallel_result[:conflicts]),
        "error_details" => error_details
      )
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end
  end
end
