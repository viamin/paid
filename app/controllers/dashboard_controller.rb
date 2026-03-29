# frozen_string_literal: true

class DashboardController < ApplicationController
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
    unless @agent_run.active?
      redirect_to dashboard_path, status: :see_other, notice: "Agent run is no longer active."
      return
    end

    # External cleanup runs first; we only update status if this succeeds
    begin
      AgentRuns::Cancel.call(agent_run: @agent_run, skip_status_update: true)
    rescue StandardError => e
      Rails.logger.error(
        message: "agent_execution.cancel_failed",
        agent_run_id: @agent_run.id,
        error_class: e.class.name,
        error_message: e.message
      )
      redirect_to dashboard_path, status: :see_other, alert: "Unable to cancel agent run. Please try again."
      return
    end

    cancelled = false

    @agent_run.with_lock do
      # The run may have completed while we were performing external cancellation
      if @agent_run.active?
        @agent_run.cancel!
        cancelled = true
      end
    end

    if cancelled
      redirect_to dashboard_path, status: :see_other, notice: "Agent run cancelled."
    else
      redirect_to dashboard_path, status: :see_other, notice: "Agent run finished before it could be cancelled."
    end
  end

  private

  def live_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end

  def set_live_agent_run
    @agent_run = live_agent_runs.find(params[:id])
  end
end
