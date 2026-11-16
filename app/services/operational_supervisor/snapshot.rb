# frozen_string_literal: true

module OperationalSupervisor
  class Snapshot
    # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-002, OPERATIONAL-SUPERVISOR-004
    WINDOW = 30.days
    MAX_PROJECTS = 20
    TOP_N = 10
    METRIC_KEYS = %w[
      issue_to_pr_conversion
      pr_to_merge_conversion
      cost_per_merged_pr
      rework_runs_per_pr
      paid_authored_pr_commit_count
      stage_age
      guardrail_rate
      escalation_rate
      queue_starvation
    ].freeze

    def self.call(account:, now: Time.current)
      new(account:, now:).call
    end

    def initialize(account:, now:)
      @account = account
      @now = now
    end

    def call
      return if projects.empty?

      {
        version: "delivery_health_snapshot_v1",
        account_id: account.id,
        generated_at: timestamp(now),
        project_limit: MAX_PROJECTS,
        project_ids: projects.map(&:id),
        projects: project_facts,
        rollups: rollups,
        metrics: metrics,
        queue: queue_facts
      }
    end

    private

    attr_reader :account, :now

    def projects
      @projects ||= account.projects.order(:id).find_each.lazy
        .select { |project| FeatureFlags.enabled?(:operational_supervisor, project:) }
        .first(MAX_PROJECTS)
    end

    def project_ids
      @project_ids ||= projects.map(&:id)
    end

    def project_facts
      projects.map do |project|
        {
          project_id: project.id,
          queue_depth: queue_depths.fetch(project.id, 0)
        }
      end
    end

    def rollups
      {
        run_statuses: window_runs.group(:status).count.sort.to_h,
        guardrail_violation_count: window_runs.where.not(guardrail_violation_type: nil).count,
        anomaly_severities: AgentRunAnomaly.where(project_id: project_ids, created_at: window).group(:severity).count.sort.to_h,
        pr_review_phases: pull_requests.group(:pr_review_phase).count.sort.to_h
      }
    end

    def metrics
      [
        ratio_metric("issue_to_pr_conversion", issue_pr_numerator, source_issues.count,
          "non-pull-request issues created in the window with a completed run that recorded a pull-request number"),
        ratio_metric("pr_to_merge_conversion", merged_pull_requests.count, source_pull_requests.count,
          "pull requests created in the window whose current lifecycle phase is merged"),
        ratio_metric("cost_per_merged_pr", window_cost_cents, merged_pull_requests.count,
          "billable agent-run token usage created in the window divided by merged pull requests from the source cohort"),
        ratio_metric("rework_runs_per_pr", rework_runs.count, rework_pull_request_count,
          "agent runs in the window that recorded a source pull-request number"),
        unavailable_metric("paid_authored_pr_commit_count",
          "no typed Paid-authored commit-count primitive is currently available"),
        stage_age_metric,
        ratio_metric("guardrail_rate", window_runs.where.not(guardrail_violation_type: nil).count, window_runs.count,
          "agent runs created in the window with a machine-readable guardrail violation"),
        ratio_metric("escalation_rate", escalated_pull_requests.count, pull_requests.count,
          "pull requests observed in the window whose current review phase is escalated"),
        queue_starvation_metric
      ]
    end

    def ratio_metric(key, numerator, denominator, inclusion_rule)
      metric(key:, numerator:, denominator:, inclusion_rule:).merge(
        availability: denominator.positive? ? "available" : "unavailable",
        value: denominator.positive? ? numerator.fdiv(denominator) : nil
      )
    end

    def unavailable_metric(key, inclusion_rule)
      metric(key:, numerator: nil, denominator: 0, inclusion_rule:).merge(availability: "unavailable", value: nil)
    end

    def stage_age_metric
      stages = source_issues.group(:paid_state).minimum(:github_created_at).sort.to_h.transform_values do |created_at|
        created_at ? (now - created_at).to_i : nil
      end

      metric(key: "stage_age", numerator: source_issues.count, denominator: source_issues.count,
        inclusion_rule: "non-pull-request issues created in the window, grouped by current paid lifecycle state").merge(
          availability: stages.empty? ? "unavailable" : "available",
          value: stages
        )
    end

    def queue_starvation_metric
      metric(key: "queue_starvation", numerator: queue_facts[:oldest].size, denominator: queue_depths.values.sum,
        inclusion_rule: "oldest queued agent runs ordered by queue-entered timestamp then run ID; this is an observation, not a starvation judgment").merge(
          availability: queue_depths.values.sum.positive? ? "available" : "unavailable",
          value: queue_facts[:oldest].map { |entry| entry[:queue_age_seconds] }
        )
    end

    def metric(key:, numerator:, denominator:, inclusion_rule:)
      {
        key:,
        window: { started_at: timestamp(window.begin), ended_at: timestamp(window.end) },
        numerator:,
        denominator:,
        inclusion_rule:
      }
    end

    def queue_facts
      @queue_facts ||= {
        ordering: "queue_entered_at_ascending_then_agent_run_id_ascending",
        limit: TOP_N,
        oldest: queued_runs.order(queue_entered_at: :asc, id: :asc).limit(TOP_N).pluck(:id, :project_id, :queue_entered_at).map do |id, project_id, entered_at|
          { agent_run_id: id, project_id:, queue_age_seconds: (now - entered_at).to_i }
        end
      }
    end

    def queue_depths
      @queue_depths ||= queued_runs.group(:project_id).count
    end

    def window
      @window ||= (now - WINDOW)..now
    end

    def window_runs
      @window_runs ||= AgentRun.where(project_id: project_ids, created_at: window)
    end

    def queued_runs
      @queued_runs ||= AgentRun.where(project_id: project_ids, status: "queued").where.not(queue_entered_at: nil)
    end

    def source_issues
      @source_issues ||= Issue.where(project_id: project_ids, is_pull_request: false, github_created_at: window)
    end

    def source_pull_requests
      @source_pull_requests ||= Issue.where(project_id: project_ids, is_pull_request: true, github_created_at: window)
    end

    def pull_requests
      @pull_requests ||= Issue.where(project_id: project_ids, is_pull_request: true, github_updated_at: window)
    end

    def merged_pull_requests
      @merged_pull_requests ||= source_pull_requests.where(pr_review_phase: "merged")
    end

    def escalated_pull_requests
      @escalated_pull_requests ||= pull_requests.where(pr_review_phase: "escalated")
    end

    def issue_pr_numerator
      source_issues.joins(:agent_runs).where(agent_runs: { status: "completed" }).where.not(agent_runs: { pull_request_number: nil }).distinct.count
    end

    def rework_runs
      @rework_runs ||= window_runs.where.not(source_pull_request_number: nil)
    end

    def rework_pull_request_count
      rework_runs.distinct.count(Arel.sql("(project_id, source_pull_request_number)"))
    end

    def window_cost_cents
      TokenUsage.billable.joins(:agent_run).where(agent_runs: { project_id: project_ids }).where(token_usages: { created_at: window }).sum(:cost_cents)
    end

    def timestamp(value)
      value.utc.iso8601
    end
  end
end
