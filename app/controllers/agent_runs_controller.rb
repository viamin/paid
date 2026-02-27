# frozen_string_literal: true

class AgentRunsController < ApplicationController
  def index
    base_scope = policy_scope(AgentRun).includes(:project, :issue)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @agent_runs = pagy(@q.result)
  end
end
