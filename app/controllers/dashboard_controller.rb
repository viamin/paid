# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!

  def show
    @stats = Dashboard::Stats.call(account: current_account)
  end

  def live
    @active_runs = account_agent_runs.active.includes(:project, :issue).recent.limit(20)
    @recent_runs = account_agent_runs.finished.includes(:project, :issue).recent.limit(10)
    @stats = Dashboard::LiveStats.call(account: current_account)
  end

  def cancel_run
    agent_run = account_agent_runs.find(params[:id])
    agent_run.cancel!
    head :ok
  end

  private

  def account_agent_runs
    AgentRun.joins(:project).where(projects: { account_id: current_account.id })
  end
end
