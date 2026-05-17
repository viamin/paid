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
    @quality_paused_projects = current_account.projects
      .where.not(quality_paused_at: nil)
      .order(quality_paused_at: :desc)
      .limit(10)
    @recent_activity = Dashboard::RecentActivity.call(account: current_account)
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

  def cancel_run
    cancel_agent_run(@agent_run, redirect_path: dashboard_path)
  end

  private

  def live_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end

  def set_live_agent_run
    @agent_run = live_agent_runs.find(params[:id])
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
end
