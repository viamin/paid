# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
    @stats = Dashboard::Stats.call(account: current_account)
  end

  def live
    @active_runs = account_agent_runs.active.includes(:project, :issue).recent.limit(20)
    @recent_runs = account_agent_runs.finished.includes(:project, :issue)
      .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC")).limit(10)
    @stats = Dashboard::LiveStats.call(account: current_account)
  end

  def cancel_run
    agent_run = account_agent_runs.find(params[:id])
    unless agent_run.active?
      redirect_to live_dashboard_path, status: :see_other, notice: "Run is no longer active."
      return
    end
    agent_run.cancel!
    redirect_to live_dashboard_path, status: :see_other
  end

  private

  def account_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end
end
