# frozen_string_literal: true

class AgentRunsController < ApplicationController
  # policy_scope handles authorization; verify_policy_scoped is enforced by ApplicationController
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AgentRun).includes(:project, issue: :project)
    @q = base_scope.ransack(params[:q])

    if params[:sort] == "queue"
      @q.sorts = nil
      @agent_runs = apply_ransack_filters(@q).queue_order_display
    else
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @agent_runs = @q.result
    end

    @pagy, @agent_runs = pagy(@agent_runs)
    AgentRun.preload_source_pull_requests(@agent_runs)
    cache_key = AgentRun.provider_options_cache_key_for(account_id: current_account.id)
    @provider_options = base_scope.distinct_effective_providers(cache_key: cache_key)
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

  private

  def apply_ransack_filters(search)
    search.result
  end
end
