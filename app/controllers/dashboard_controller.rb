# frozen_string_literal: true

class DashboardController < ApplicationController
  include AgentRunCancellable

  before_action :authenticate_user!
  before_action :set_live_agent_run, only: :cancel_run

  def show
    @time_range = valid_time_range
    @status_filter = valid_status_filter
    @goal_filter = valid_goal_filter
    @live_stats = Dashboard::LiveStats.call(account: current_account)
    @queue_preview = Dashboard::QueuePreview.call(user: current_user)
    @active_runs = live_agent_runs.active.includes(:runner, :issue, :model_selection, project: [ :created_by, :account ])
      .order("agent_runs.created_at DESC")
      .limit(20)
    AgentRun.preload_final_runner_records(@active_runs)
    AgentRun.preload_source_pull_requests(@active_runs)
    AgentRun.preload_created_issue_records(@active_runs)
    @paused_runs = live_agent_runs.paused.includes(:runner, :issue, :model_selection, project: [ :created_by, :account ])
      .order(paused_at: :desc, created_at: :desc)
      .limit(20)
      .to_a
    AgentRun.preload_final_runner_records(@paused_runs)
    AgentRun.preload_source_pull_requests(@paused_runs)
    AgentRun.preload_created_issue_records(@paused_runs)
    @quality_paused_projects = current_account.projects
      .where.not(quality_paused_at: nil)
      .order(quality_paused_at: :desc)
      .limit(10)
    @retry_limited_issues = Issue.joins(:project)
      .where(projects: { account_id: current_account.id })
      .where.not(runner_retry_abandoned_at: nil)
      .includes(:project)
      .order(runner_retry_abandoned_at: :desc)
      .limit(20)
      .to_a
    @recent_activity = Dashboard::RecentActivity.call(account: current_account)
  end

  def eligibility_breakdown
    @eligibility_breakdown = Dashboard::EligibilityBreakdown.call(user: current_user)
    render partial: "dashboard/eligibility_breakdown", locals: { breakdowns: @eligibility_breakdown }
  end

  def needs_input
    @scoped_project = scoped_needs_input_project
    @needs_input_entries = Dashboard::NeedsInputQueue.call(user: current_user, project: @scoped_project)
  end

  def metrics
    @time_range = valid_time_range
    @stats = Dashboard::Stats.call(
      account: current_account,
      time_range: @time_range,
      only: Dashboard::Stats::METRICS_SECTIONS
    )
    render partial: "dashboard/metrics",
      locals: { stats: @stats, account: current_account, time_range: @time_range }
  end

  def performance
    @time_range = valid_time_range
    @status_filter = valid_status_filter
    @goal_filter = valid_goal_filter
    @stats = Dashboard::Stats.call(
      account: current_account,
      time_range: @time_range,
      status_filter: @status_filter,
      goal_filter: @goal_filter,
      only: Dashboard::Stats::PERFORMANCE_SECTIONS
    )
    render partial: "dashboard/performance",
      locals: { stats: @stats, time_range: @time_range, status_filter: @status_filter, goal_filter: @goal_filter }
  end

  def decision_metrics
    @time_range = valid_time_range
    @decision_metrics = Analytics::OrchestrationDecisions::Report.call(
      relation: orchestration_decisions_scope,
      filters: decision_metrics_filters
    )
    render partial: "dashboard/orchestration_decisions",
      locals: { report: @decision_metrics, time_range: @time_range }
  end

  def knowledge_stats
    @knowledge_stats = Knowledge::DashboardStats.call(account: current_account)
    render partial: "dashboard/knowledge_widget", locals: { knowledge_stats: @knowledge_stats }
  end

  def runner_health
    @runner_health = Dashboard::RunnerHealth.call(account: current_account)
    render partial: "dashboard/runner_health", locals: @runner_health
  end

  def queue_health
    @queue_health = Scaling::QueueMonitor.cached_for_account(current_account)
    render partial: "dashboard/queue_health", locals: { queue_depths: @queue_health.queue_depths, healthy: @queue_health.healthy? }
  end

  def github_health
    @github_health = Dashboard::GithubHealth.call(account: current_account)
    render partial: "dashboard/github_health", locals: @github_health
  end

  def auth_health
    @auth_health = Runners::AuthHealth.call(account: current_account)
    render partial: "dashboard/auth_health_frame", locals: { auth_health: @auth_health }
  end

  def pr_cycle_time
    @time_range = valid_time_range
    cutoff = valid_outlier_cutoff
    data = Dashboard::PrCycleTimeSeries.call(
      account: current_account,
      time_range: @time_range,
      outlier_cutoff_hours: cutoff
    )
    render partial: "dashboard/pr_cycle_time",
      locals: { data: data, time_range: @time_range, outlier_cutoff: cutoff }
  end

  def cancel_run
    authorize @agent_run, :cancel?
    @queue_preview_request = queue_preview_request?
    result = cancel_agent_run_result(@agent_run)
    refresh_queue_preview = @queue_preview_request || result.cancelled?

    Dashboard::CacheVersion.bump(current_account, scope: Dashboard::CacheVersion::LISTS_SCOPE) if refresh_queue_preview
    load_queue_preview if @queue_preview_request

    respond_to do |format|
      format.html { redirect_to dashboard_path, status: :see_other, notice: result.message }
      format.turbo_stream do
        @cancel_result = result
        render "dashboard/cancel_run", formats: :turbo_stream
      end
    end
  end

  private

  def live_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end

  def set_live_agent_run
    @agent_run = live_agent_runs.find(params[:id])
  end

  def load_queue_preview
    @queue_preview = Dashboard::QueuePreview.call(user: current_user)
    @quality_paused_projects = current_account.projects
      .where.not(quality_paused_at: nil)
      .order(quality_paused_at: :desc)
      .limit(10)
  end

  def queue_preview_request?
    params[:source] == "queue_preview"
  end

  def valid_time_range
    time_range = params[:time_range].to_s
    Dashboard::Stats::TIME_RANGES.include?(time_range) ? time_range : "cumulative"
  end

  def valid_status_filter
    status = params[:status].to_s
    Dashboard::Stats::VALID_STATUSES.include?(status) ? status : "all"
  end

  def valid_goal_filter
    goal = params[:goal].to_s
    Dashboard::Stats::VALID_GOALS.include?(goal) ? goal : "all"
  end

  def valid_outlier_cutoff
    cutoff = params[:outlier_cutoff].to_f
    cutoff.positive? ? cutoff : Dashboard::PrCycleTimeSeries::DEFAULT_OUTLIER_CUTOFF_HOURS
  end

  def orchestration_decisions_scope
    OrchestrationDecision.joins(:project).where(projects: { account_id: current_account.id })
  end

  def decision_metrics_filters
    starts_at = time_range_start(@time_range)
    starts_at ? { from: starts_at } : {}
  end

  def time_range_start(time_range)
    case time_range
    when "24h"
      24.hours.ago
    when "7d"
      7.days.ago
    when "30d"
      30.days.ago
    end
  end

  def scoped_needs_input_project
    return if params[:project_id].blank?

    project = policy_scope(Project).find(params[:project_id])
    authorize project, :show?
    project
  end
end
