# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!
  before_action :set_live_agent_run, only: :cancel_run

  def show
    @stats = Dashboard::Stats.call(account: current_account)
  end

  def live
    @live_stats = Dashboard::LiveStats.call(account: current_account)
    @active_runs = live_agent_runs.active.includes(:project, :issue)
      .order("agent_runs.created_at DESC")
      .limit(20)
    @recent_runs = live_agent_runs.finished.includes(:project, :issue)
      .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC"))
      .limit(10)
  end

  def cancel_run
    @agent_run.with_lock do
      unless @agent_run.active?
        redirect_to live_dashboard_path, status: :see_other, notice: "Agent run is no longer active."
        return
      end

      @agent_run.cancel!
    end

    # External cleanup runs outside the row lock as best-effort
    AgentRuns::Cancel.call(agent_run: @agent_run, skip_status_update: true)

    redirect_to live_dashboard_path, status: :see_other, notice: "Agent run cancelled."
  end

  private

  def live_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end

  def set_live_agent_run
    @agent_run = live_agent_runs.find(params[:id])
  end
end
