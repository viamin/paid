# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
    @stats = Dashboard::Stats.call(account: current_account)
  end

  def live
    @active_runs = account_agent_runs.active.includes(:project, :issue)
      .order("agent_runs.created_at DESC").limit(20)
    @recent_runs = account_agent_runs.finished.includes(:project, :issue)
      .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC")).limit(10)
    @stats = Dashboard::LiveStats.call(account: current_account)
  end

  def cancel_run
    agent_run = account_agent_runs.find(params[:id])
    cancelled = agent_run.with_lock do
      agent_run.reload
      if agent_run.active?
        agent_run.cancel!
        true
      end
    end
    if cancelled
      redirect_to live_dashboard_path, status: :see_other
    else
      redirect_to live_dashboard_path, status: :see_other, notice: "Run is no longer active."
    end
  end

  private

  def account_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end
end
