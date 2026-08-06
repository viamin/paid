# frozen_string_literal: true

module Roi
  class MetricsCalculator
    def self.call(...)
      new(...).call
    end

    def initialize(agent_runs:, related_runs: agent_runs, window: nil)
      @agent_runs = agent_runs
      @related_runs = related_runs
      @window = window
    end

    def call
      runs = scoped_runs
      return empty_summary if runs.empty?

      accepted_runs = runs.filter_map { |run| accepted_snapshot_for(run) }
      total_cost_cents = runs.sum { |run| run.cost_cents.to_i }
      issue_run_counts = runs.group_by(&:issue_id).transform_values(&:size)
      later_run_times_by_issue = load_later_run_times(accepted_runs)

      cycle_times = accepted_runs.filter_map { |snapshot| cycle_time_hours_for(snapshot) }
      rework_count = accepted_runs.count { |snapshot| rework?(snapshot, issue_run_counts:) }
      defect_escape_count = accepted_runs.count { |snapshot| defect_escape?(snapshot, later_run_times_by_issue:) }
      accepted_count = accepted_runs.size
      created_count = runs.size

      {
        created_pr_count: created_count,
        accepted_pr_count: accepted_count,
        total_cost_cents: total_cost_cents,
        merge_rate: percentage(accepted_count, created_count),
        average_cycle_time_hours: average(cycle_times),
        rework_rate: percentage(rework_count, accepted_count),
        defect_escape_rate: percentage(defect_escape_count, accepted_count),
        cost_per_accepted_pr_cents: accepted_count.zero? ? nil : (total_cost_cents.to_f / accepted_count).round
      }
    end

    private

    attr_reader :agent_runs, :related_runs, :window

    def scoped_runs
      @scoped_runs ||= if relation_like?(agent_runs)
        scoped_relation(agent_runs).includes(:issue, :quality_metrics).order(:created_at).to_a
      else
        scoped_array(agent_runs)
      end
    end

    def accepted_snapshot_for(run)
      merged_metric = run.quality_metrics
        .select { |metric| metric.metric_type == "human" && metric.scores&.key?("pr_merged") }
        .max_by(&:created_at)
      return unless merged_metric
      return unless merged_metric.scores["pr_merged"].to_f >= 1.0

      {
        run: run,
        issue: run.issue,
        accepted_at: merged_metric.created_at || run.completed_at || run.updated_at
      }
    end

    def cycle_time_hours_for(snapshot)
      started_at = snapshot[:issue]&.github_created_at || snapshot[:run].created_at
      accepted_at = snapshot[:accepted_at]
      return if started_at.blank? || accepted_at.blank?

      ((accepted_at - started_at) / 1.hour).round(2)
    end

    def rework?(snapshot, issue_run_counts:)
      issue = snapshot[:issue]
      run = snapshot[:run]

      run.iterations.to_i > 1 ||
        issue_run_counts.fetch(run.issue_id, 0) > 1 ||
        issue&.pr_followup_count.to_i.positive? ||
        issue&.review_goal_retry_count.to_i.positive? ||
        issue&.draft_review_count.to_i.positive?
    end

    def defect_escape?(snapshot, later_run_times_by_issue:)
      issue_id = snapshot[:run].issue_id
      return false if issue_id.blank?

      later_run_times_by_issue.fetch(issue_id, []).any? { |created_at| created_at > snapshot[:accepted_at] }
    end

    def load_later_run_times(accepted_runs)
      issue_ids = accepted_runs.map { |snapshot| snapshot[:run].issue_id }.compact.uniq
      return {} if issue_ids.empty?

      if relation_like?(related_runs)
        scope = related_runs.excluding_synthetic.where(issue_id: issue_ids).where.not(goal: "create_issue")
        scope = scope.where(created_at: window) if window

        scope.pluck(:issue_id, :created_at).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(issue_id, created_at), memo|
          memo[issue_id] << created_at
        end
      else
        related_runs
          .select { |run| issue_ids.include?(run.issue_id) && run.goal != "create_issue" && !run.synthetic_operational_run? }
          .select { |run| window.nil? || window.cover?(run.created_at) }
          .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |run, memo|
            memo[run.issue_id] << run.created_at
          end
      end
    end

    def relation_like?(runs)
      runs.respond_to?(:where)
    end

    def scoped_relation(runs)
      scope = runs.reported_create_pr.where(status: "completed").where.not(pull_request_number: nil)
      scope = scope.where(created_at: window) if window
      scope
    end

    def scoped_array(runs)
      runs
        .select do |run|
          run.goal == "create_pr" &&
            !run.synthetic_operational_run? &&
            run.status == "completed" &&
            run.pull_request_number.present? &&
            (window.nil? || window.cover?(run.created_at))
        end
        .sort_by(&:created_at)
    end

    def average(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round(2)
    end

    def percentage(numerator, denominator)
      return nil if denominator.zero?

      (numerator.to_f / denominator * 100).round(1)
    end

    def empty_summary
      {
        created_pr_count: 0,
        accepted_pr_count: 0,
        total_cost_cents: 0,
        merge_rate: nil,
        average_cycle_time_hours: nil,
        rework_rate: nil,
        defect_escape_rate: nil,
        cost_per_accepted_pr_cents: nil
      }
    end
  end
end
