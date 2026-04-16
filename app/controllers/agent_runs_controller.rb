# frozen_string_literal: true

class AgentRunsController < ApplicationController
  # policy_scope handles authorization; verify_policy_scoped is enforced by ApplicationController
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AgentRun).includes(:project, issue: :project)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @agent_runs = pagy(@q.result)
    AgentRun.preload_source_pull_requests(@agent_runs)
    @provider_options = base_scope.distinct_effective_providers
  end

  def pause_scheduler
    authorize current_account, :update?
    current_account.update!(scheduler_paused_at: Time.current) unless current_account.scheduler_paused?
    redirect_to agent_runs_path, notice: "Scheduler paused. Queued runs will not start until resumed."
  end

  def resume_scheduler
    authorize current_account, :update?
    if current_account.scheduler_paused?
      current_account.update!(scheduler_paused_at: nil)
      ProcessRunQueueJob.perform_later
    end
    redirect_to agent_runs_path, notice: "Scheduler resumed."
  end
end
