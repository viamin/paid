# frozen_string_literal: true

class AgentRunsController < ApplicationController
  include AgentRunFilterOptions
  include AgentRunIndexOrdering

  # policy_scope handles authorization; verify_policy_scoped is enforced by ApplicationController
  skip_after_action :verify_authorized, only: :index

  def index
    # @spec AGENT-RUNS-INDEX-001
    # Synthetic operational runs (e.g. live-preview provisioning) reuse the
    # agent-run lifecycle but never execute a real agent. They are excluded from
    # this account-wide view for consistency with the project-scoped run list.
    base_scope = policy_scope(AgentRun).excluding_synthetic.excluding_list_payload
      .includes(:runner, project: [ :created_by, :account ], issue: :project)
    @q = base_scope.ransack(params[:q])
    queue_fairness_mode = current_account.tenant_setting!.resolved_queue_fairness_mode

    @q.sorts = "created_at desc" if @q.sorts.empty?
    @agent_runs = ordered_agent_runs(@q, queue_fairness_mode:)

    @pagy, @agent_runs = pagy(@agent_runs)
    AgentRun.preload_final_runner_records(@agent_runs)
    AgentRun.preload_source_pull_requests(@agent_runs)
    AgentRun.preload_created_issue_records(@agent_runs)
    cache_key = AgentRun.runner_options_cache_key_for(account_id: current_account.id)
    @runner_options = base_scope.distinct_effective_runner_options(account_id: current_account.id, cache_key: cache_key)
    filter_options_cache_key = AgentRun.filter_options_cache_key_for(account_id: current_account.id)
    @filter_options = available_filter_options(base_scope, cache_key: filter_options_cache_key)
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
end
