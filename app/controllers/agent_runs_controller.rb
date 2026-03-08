# frozen_string_literal: true

class AgentRunsController < ApplicationController
  # policy_scope handles authorization; verify_policy_scoped is enforced by ApplicationController
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AgentRun).includes(:project, :issue)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @agent_runs = pagy(@q.result)
  end
end
