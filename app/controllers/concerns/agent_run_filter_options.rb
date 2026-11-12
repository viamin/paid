# frozen_string_literal: true

module AgentRunFilterOptions
  private

  def available_filter_options(scope, cache_key:)
    scope.distinct_filter_options(cache_key: cache_key)
  end

  def agent_run_search_params
    params.fetch(:q, {}).permit(
      :s,
      :status_eq,
      :agent_type_eq,
      :trigger_type_eq,
      :goal_eq,
      :effective_runner_eq,
      :branch_name_cont,
      :temporal_workflow_id_cont,
      :branch_name_or_temporal_workflow_id_cont,
      status_in: [],
      agent_type_in: [],
      trigger_type_in: [],
      goal_in: [],
      effective_runner_in: []
    ).to_h
  end
end
