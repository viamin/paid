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

  AGENT_RUN_PRIORITY_STYLES = {
    manual: { bg: "bg-sky-100", text: "text-sky-700" },
    auto_continue: { bg: "bg-violet-100", text: "text-violet-700" },
    auto_pick: { bg: "bg-teal-100", text: "text-teal-700" },
    unknown: { bg: "bg-gray-100", text: "text-gray-600" }
  }.freeze

  def agent_run_priority_badge(run)
    priority = run.queue_priority_tier
    styles = AGENT_RUN_PRIORITY_STYLES.fetch(priority, AGENT_RUN_PRIORITY_STYLES[:unknown])
    tag.span(
      run.queue_priority_label,
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  PAID_STATE_STYLES = {
    "new" => { bg: "bg-gray-100", text: "text-gray-700", label: "New" },
    "planning" => { bg: "bg-purple-100", text: "text-purple-700", label: "Planning" },
    "in_progress" => { bg: "bg-blue-100", text: "text-blue-700", label: "In Progress" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" },
    "needs_input" => { bg: "bg-amber-100", text: "text-amber-700", label: "Needs Input" },
    "recommend_close" => { bg: "bg-orange-100", text: "text-orange-700", label: "Recommend Close" }
  }.freeze

  def paid_state_badge(state)
    styles = PAID_STATE_STYLES[state] || PAID_STATE_STYLES["new"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  ISSUE_LIFECYCLE_DISPLAY = {
    blocked: { emoji: "\u{1F550}", label: "Blocked" },
    in_progress: { emoji: "\u{1F9E0}", label: "In Progress" },
    eligible: { emoji: "\u26A1\uFE0F", label: "Unblocked", title: "Unblocked — no dependencies or active work" }
  }.freeze

  def issue_lifecycle_badge(status)
    display = ISSUE_LIFECYCLE_DISPLAY[status] || ISSUE_LIFECYCLE_DISPLAY[:eligible]
    tag.span(
      "#{display[:emoji]} #{display[:label]}",
      title: display[:title] || display[:label],
      class: "inline-flex items-center text-sm"
    )
  end

  SERVICE_CONTAINER_STATUS_STYLES = {
    "stopped" => { bg: "bg-gray-100", text: "text-gray-700", label: "Stopped" },
    "starting" => { bg: "bg-yellow-100", text: "text-yellow-800", label: "Starting" },
    "running" => { bg: "bg-green-100", text: "text-green-700", label: "Running" },
    "error" => { bg: "bg-red-100", text: "text-red-700", label: "Error" }
  }.freeze

  LOCAL_TIME_FORMATS = {
    long: "%B %d, %Y at %l:%M %p UTC",
    short: "%b %d, %Y %H:%M UTC",
    date: "%b %d, %Y",
    time: "%H:%M:%S UTC",
    relative: nil
  }.freeze

  def service_container_status_badge(status)
    styles = SERVICE_CONTAINER_STATUS_STYLES[status] || SERVICE_CONTAINER_STATUS_STYLES["stopped"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  def safe_github_url?(url)
    return false if url.blank?

    uri = URI.parse(url)
    uri.scheme == "https" && uri.host == "github.com"
  rescue URI::InvalidURIError
    false
  end

  # Returns context display info for an agent run as a hash with :type and optional :label, :url, :classes.
  # Centralizes the priority logic so the ERB template only needs a simple case statement.
  def agent_run_context(run)
    if run.create_pr_goal?
      create_pr_context(run)
    elsif run.create_issue_goal?
      create_issue_context(run)
    elsif run.review_goal?
      review_context(run)
    else
      { type: :placeholder }
    end
  end

  # Renders a <time> element that displays in the user's local timezone via Stimulus.
  # Falls back to a UTC-formatted string for non-JS clients.
  #
  # Formats: :long, :short, :date, :time, :relative
  def local_time(time, format: :long)
    return if time.nil?

    utc = time.utc
    format_key = format || :long
    fallback = local_time_fallback(utc, format_key)

    tag.time(
      fallback,
      datetime: utc.iso8601,
      data: { controller: "local-time", local_time_format_value: format_key.to_s }
    )
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

  # Renders the context cell for an agent run, including tooltip support.
  # Desktop: native title tooltip on hover. Mobile: tappable info icon.
  def agent_run_context_display(run)
    context = agent_run_context(run)
    inner = case context[:type]
    when :link
      link_to(context[:label], context[:url], target: "_blank", rel: "noopener noreferrer",
        class: "text-indigo-600 hover:text-indigo-900", title: context[:tooltip])
    when :text
      tag.span(context[:label], class: context[:classes], title: context[:tooltip])
    when :pending
      tag.span("Creating issue\u2026", class: "italic text-gray-500")
    else
      tag.span("-", class: "text-gray-400")
    end

    if context[:tooltip].present?
      tooltip_id = "tooltip_#{run.id}"
      tag.span(class: "inline-flex items-center gap-1", data: { controller: "tooltip" }) do
        safe_join([
          inner,
          tag.button(
            tag.svg(
              tag.path(d: "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"),
              class: "h-4 w-4", fill: "none", viewBox: "0 0 24 24", stroke: "currentColor",
              "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
              aria: { hidden: "true" }, focusable: "false"
            ),
            type: "button",
            class: "[@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))]:hidden text-gray-400 hover:text-gray-600",
            data: { action: "click->tooltip#toggle" },
            aria: { label: "Show context title", describedby: tooltip_id, expanded: "false", controls: tooltip_id }
          ),
          tag.span(
            context[:tooltip],
            id: tooltip_id,
            role: "tooltip",
            aria: { hidden: "true" },
            class: "hidden fixed z-50 w-48 rounded bg-gray-900 px-2 py-1 text-xs text-white shadow-lg",
            data: { tooltip_target: "content" }
          )
        ])
      end
    else
      inner
    end
  end

  # Redacts potential secrets from error messages before displaying them in the UI.
  # Uses the Knowledge::Redaction::Redactor for consistent secret detection.
  def redacted_error_message(message)
    return nil if message.blank?

    Knowledge::Redaction::Redactor.call(text: message).clean_text
  end

  def create_pr_context(run)
    if run.issue.present?
      prefix = run.issue.is_pull_request? ? "PR" : "Issue"
      label = "#{prefix} ##{run.issue.github_number}"
      github_link_or_text(label, label, run.issue.github_url, tooltip: run.issue.title)
    elsif run.source_pull_request_number.present?
      { type: :text, label: "PR ##{run.source_pull_request_number}", classes: "text-gray-700" }
    elsif run.pull_request_number.present?
      github_link_or_text("PR ##{run.pull_request_number}", "PR ##{run.pull_request_number}", run.pull_request_url)
    else
      { type: :placeholder }
    end
  end

  def create_issue_context(run)
    if safe_github_url?(run.created_issue_url)
      label = run.created_issue_number.present? ? "Issue ##{run.created_issue_number}" : "Issue"
      { type: :link, label: label, url: run.created_issue_url }
    elsif run.finished?
      { type: :placeholder }
    else
      { type: :pending }
    end
  end

  # Tooltip not available here: source_pull_request_number has no associated title
  # column, and fetching titles from GitHub would introduce N+1 queries.
  def review_context(run)
    if run.source_pull_request_number.present?
      { type: :text, label: "PR ##{run.source_pull_request_number}", classes: "text-gray-700" }
    else
      { type: :placeholder }
    end
  end

  def local_time_fallback(utc, format)
    format_key = format.to_sym
    raise ArgumentError, "Unknown local_time format: #{format_key.inspect}" unless LOCAL_TIME_FORMATS.key?(format_key)

    fmt = LOCAL_TIME_FORMATS[format_key]
    if fmt
      utc.strftime(fmt).squish
    else
      distance = time_ago_in_words(utc)
      utc > Time.current ? "in #{distance}" : "#{distance} ago"
    end
  end

  def github_link_or_text(link_label, text_label, url, tooltip: nil)
    if safe_github_url?(url)
      { type: :link, label: link_label, url: url, tooltip: tooltip }
    else
      { type: :text, label: text_label, classes: "text-gray-700", tooltip: tooltip }
    end
  end
end
