# frozen_string_literal: true

class AgentRunsController < ApplicationController
  # policy_scope handles authorization; verify_policy_scoped is enforced by ApplicationController
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AgentRun).includes(:runner, project: [ :created_by, :account ], issue: :project)
    @q = base_scope.ransack(params[:q])

    if params[:sort] == "queue" && queue_sort_compatible?
      @q.sorts.clear if @q.sorts.any?
      @agent_runs = apply_ransack_filters(@q).queue_order_display
    else
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @agent_runs = @q.result
    end

    @pagy, @agent_runs = pagy(@agent_runs)
    AgentRun.preload_final_runner_records(@agent_runs)
    AgentRun.preload_source_pull_requests(@agent_runs)
    cache_key = AgentRun.runner_options_cache_key_for(account_id: current_account.id)
    @runner_options = base_scope.distinct_effective_runner_options(account_id: current_account.id, cache_key: cache_key)
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

  def queue_sort_compatible?
    status_filter = params.dig(:q, :status_eq)
    # Queue sort is only meaningful when already filtered to an unfinished
    # status — otherwise queue_order_display's .unfinished scope silently
    # hides completed/failed runs from the default (unfiltered) view.
    return false if status_filter.blank?

    AgentRun::UNFINISHED_STATUSES.include?(status_filter)
  end
end
