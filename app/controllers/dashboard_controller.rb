# frozen_string_literal: true

class DashboardController < ApplicationController
  include AgentRunCancellable

  before_action :authenticate_user!
  before_action :set_live_agent_run, only: :cancel_run

  def show
    @stats = Dashboard::Stats.call(account: current_account)
    @knowledge_stats = Knowledge::DashboardStats.call(account: current_account)
    @live_stats = Dashboard::LiveStats.call(account: current_account)
    @active_runs = live_agent_runs.active.includes(:project, :issue)
      .order("agent_runs.created_at DESC")
      .limit(20)
    @recent_runs = live_agent_runs.finished.includes(:project, :issue)
      .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC"))
      .limit(10)
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
end
