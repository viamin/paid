# frozen_string_literal: true

class DashboardController < ApplicationController
  include AgentRunCancellable

  before_action :authenticate_user!
  before_action :set_live_agent_run, only: :cancel_run

  def show
    @time_range = valid_time_range
    @status_filter = valid_status_filter
    @goal_filter = valid_goal_filter
    @stats = Dashboard::Stats.call(
      account: current_account,
      time_range: @time_range,
      status_filter: @status_filter,
      goal_filter: @goal_filter
    )
    @knowledge_stats = Knowledge::DashboardStats.call(account: current_account)
    @live_stats = Dashboard::LiveStats.call(account: current_account)
    @active_runs = live_agent_runs.active.includes(:project, :issue)
      .order("agent_runs.created_at DESC")
      .limit(20)
    @recent_runs = live_agent_runs.finished.includes(:project, :issue)
      .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC"))
      .limit(10)
  end

  def metrics
    @time_range = valid_time_range
    @stats = Dashboard::Stats.call(account: current_account, time_range: @time_range)
    render partial: "dashboard/metrics", locals: { stats: @stats, account: current_account, time_range: @time_range }
  end

  def performance
    @time_range = valid_time_range
    @status_filter = valid_status_filter
    @goal_filter = valid_goal_filter
    @stats = Dashboard::Stats.call(
      account: current_account,
      time_range: @time_range,
      status_filter: @status_filter,
      goal_filter: @goal_filter
    )
    render partial: "dashboard/performance",
      locals: { stats: @stats, time_range: @time_range, status_filter: @status_filter, goal_filter: @goal_filter }
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
end
