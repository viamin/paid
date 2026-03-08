# frozen_string_literal: true

module ApplicationHelper
  AGENT_RUN_STATUS_STYLES = {
    "queued" => { bg: "bg-indigo-100", text: "text-indigo-700", label: "Queued" },
    "pending" => { bg: "bg-yellow-100", text: "text-yellow-800", label: "Pending" },
    "running" => { bg: "bg-blue-100", text: "text-blue-700", label: "Running" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" },
    "cancelled" => { bg: "bg-gray-100", text: "text-gray-600", label: "Cancelled" },
    "timeout" => { bg: "bg-orange-100", text: "text-orange-700", label: "Timeout" },
    "retried" => { bg: "bg-purple-100", text: "text-purple-700", label: "Retried" },
    "auth_expired" => { bg: "bg-amber-100", text: "text-amber-700", label: "Auth Expired" },
    "rate_limited" => { bg: "bg-orange-100", text: "text-orange-700", label: "Rate Limited" }
  }.freeze

  def agent_run_status_badge(status)
    styles = AGENT_RUN_STATUS_STYLES[status] || AGENT_RUN_STATUS_STYLES["pending"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  TRIGGER_TYPE_STYLES = {
    "manual" => { bg: "bg-sky-100", text: "text-sky-700", label: "Manual" },
    "automatic" => { bg: "bg-amber-100", text: "text-amber-700", label: "Auto" }
  }.freeze

  def agent_run_trigger_badge(trigger_type)
    styles = TRIGGER_TYPE_STYLES[trigger_type] || TRIGGER_TYPE_STYLES["automatic"]
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

  SERVICE_CONTAINER_STATUS_STYLES = {
    "stopped" => { bg: "bg-gray-100", text: "text-gray-700", label: "Stopped" },
    "starting" => { bg: "bg-yellow-100", text: "text-yellow-800", label: "Starting" },
    "running" => { bg: "bg-green-100", text: "text-green-700", label: "Running" },
    "error" => { bg: "bg-red-100", text: "text-red-700", label: "Error" }
  }.freeze

  def service_container_status_badge(status)
    styles = SERVICE_CONTAINER_STATUS_STYLES[status] || SERVICE_CONTAINER_STATUS_STYLES["stopped"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  def safe_github_url?(url)
    url.present? && url.start_with?("https://github.com/")
  end

  RANSACK_PERMITTED_KEYS = %i[status_eq agent_type_eq trigger_type_eq goal_eq branch_name_cont category_eq active_eq name_cont s].freeze

  def sort_link_to(label, attribute, q)
    current_sort = q.sorts.find { |s| s.name == attribute.to_s }
    direction = current_sort&.dir == "asc" ? "desc" : "asc"
    arrow = if current_sort&.dir == "asc"
      tag.span(" \u2191", class: "ml-1")
    elsif current_sort&.dir == "desc"
      tag.span(" \u2193", class: "ml-1")
    end

    q_params = params[:q]&.permit(*RANSACK_PERMITTED_KEYS)&.to_h || {}
    link_to(
      safe_join([ label, arrow ].compact),
      url_for(request.query_parameters.except(:page, "page").merge(q: q_params.merge(s: "#{attribute} #{direction}"))),
      class: "group inline-flex items-center"
    )
  end
end
