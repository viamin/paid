# frozen_string_literal: true

module AgentRunIndexOrdering
  private

  # @spec AGENT-RUNS-INDEX-005
  def ordered_agent_runs(search, queue_fairness_mode:)
    return search.result unless params[:sort] == "queue" && queue_sort_compatible?

    search.sorts.clear if search.sorts.any?
    search.result.queue_order_display(mode: queue_fairness_mode)
  end

  def queue_sort_compatible?
    selected_statuses = Array(params.dig(:q, :status_in)).filter_map(&:presence)
    selected_statuses = Array(params.dig(:q, :status_eq)).filter_map(&:presence) if selected_statuses.empty?

    selected_statuses.present? && (selected_statuses - AgentRun::UNFINISHED_STATUSES).empty?
  end
end
