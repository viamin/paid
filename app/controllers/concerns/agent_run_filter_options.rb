# frozen_string_literal: true

module AgentRunFilterOptions
  RANSACK_SCALAR_FILTERS = %i[branch_name_or_temporal_workflow_id_cont s].freeze
  RANSACK_ARRAY_FILTERS = %i[
    status_in agent_type_in trigger_type_in goal_in effective_runner_in
  ].freeze

  private

  # @spec AGENT-RUNS-INDEX-004
  def agent_run_search_params
    permitted_array_filters = RANSACK_ARRAY_FILTERS.index_with { [] }
    params[:q]&.permit(*RANSACK_SCALAR_FILTERS, permitted_array_filters) || {}
  end

  def available_filter_options(scope, cache_key:)
    scope.distinct_filter_options(cache_key: cache_key)
  end
end
