# frozen_string_literal: true

module ApplicationHelper
  AGENT_RUN_STATUS_STYLES = {
    "pending" => { bg: "bg-yellow-100", text: "text-yellow-800", label: "Pending" },
    "running" => { bg: "bg-blue-100", text: "text-blue-700", label: "Running" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" },
    "cancelled" => { bg: "bg-gray-100", text: "text-gray-600", label: "Cancelled" },
    "timeout" => { bg: "bg-orange-100", text: "text-orange-700", label: "Timeout" }
  }.freeze

  def agent_run_status_badge(status)
    styles = AGENT_RUN_STATUS_STYLES[status] || AGENT_RUN_STATUS_STYLES["pending"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  PAID_STATE_STYLES = {
    "new" => { bg: "bg-gray-100", text: "text-gray-700", label: "New" },
    "planning" => { bg: "bg-purple-100", text: "text-purple-700", label: "Planning" },
    "in_progress" => { bg: "bg-blue-100", text: "text-blue-700", label: "In Progress" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" }
  }.freeze

  def paid_state_badge(state)
    styles = PAID_STATE_STYLES[state] || PAID_STATE_STYLES["new"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end
end
