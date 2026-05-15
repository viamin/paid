# frozen_string_literal: true

module ApplicationHelper
  MISSING_PROVIDER_ENTRY_LABEL = "Deleted provider entry"

  # Dark-mode colors for these badges are handled by the global unlayered
  # overrides in application.tailwind.css (e.g. `.dark .bg-indigo-100`),
  # which have higher cascade priority than Tailwind dark: utilities.
  AGENT_RUN_STATUS_STYLES = {
    "queued" => { bg: "bg-indigo-100", text: "text-indigo-700", label: "Queued" },
    "running" => { bg: "bg-blue-100", text: "text-blue-700", label: "Running" },
    "paused" => { bg: "bg-yellow-100", text: "text-yellow-800", label: "Paused" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "no_output" => { bg: "bg-slate-100", text: "text-slate-600", label: "No Output" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" },
    "cancelled" => { bg: "bg-gray-100", text: "text-gray-600", label: "Cancelled" },
    "timeout" => { bg: "bg-orange-100", text: "text-orange-700", label: "Timeout" },
    "retried" => { bg: "bg-purple-100", text: "text-purple-700", label: "Retried" },
    "auth_expired" => { bg: "bg-amber-100", text: "text-amber-700", label: "Auth Expired" },
    "rate_limited" => { bg: "bg-orange-100", text: "text-orange-700", label: "Rate Limited" }
  }.freeze

  def agent_run_status_badge(status)
    styles = AGENT_RUN_STATUS_STYLES[status] || AGENT_RUN_STATUS_STYLES["queued"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  def guardrail_violation_type_for(agent_run)
    agent_run.guardrail_violation_type.presence ||
      agent_run.guardrail_context&.dig("violation_type").presence
  end

  def guardrail_violation_label_for(agent_run)
    guardrail_violation_type_for(agent_run)&.tr("_", " ")&.capitalize || "Guardrail violation"
  end

  def guardrail_violation_detail_for(agent_run)
    agent_run.guardrail_context&.dig("details").presence
  end

  def agent_harness_auth_url(provider)
    return nil if provider.blank? || !AgentHarness.respond_to?(:auth_url)

    AgentHarness.auth_url(provider.to_sym)
  rescue NotImplementedError, AgentHarness::Error => e
    Rails.logger.info(
      message: "agent_execution.auth_url_unavailable",
      provider: provider,
      error_class: e.class.name,
      error_message: e.message
    )
    nil
  end

  def safe_stylesheet_link_tag(source, **options)
    safe_asset_tag { stylesheet_link_tag(source, **options) }
  end

  def safe_javascript_include_tag(source, **options)
    safe_asset_tag { javascript_include_tag(source, **options) }
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
    label_p1: { bg: "bg-red-100", text: "text-red-700" },
    manual: { bg: "bg-sky-100", text: "text-sky-700" },
    label_p2: { bg: "bg-orange-100", text: "text-orange-700" },
    auto_continue: { bg: "bg-violet-100", text: "text-violet-700" },
    label_p3: { bg: "bg-amber-100", text: "text-amber-700" },
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

  def agent_run_provider_displays(runs)
    runs = runs.to_a
    routed_providers_by_owner_and_id = routed_providers_for_runs(runs)
    configured_providers_by_owner_and_key = configured_providers_for_runs(runs)

    runs.each_with_object({}) do |run, displays|
      displays[run.id] =
        if run.final_provider.present?
          provider_display_for_identifier(
            run.final_provider,
            provider: provider_for_identifier(run, configured_providers_by_owner_and_key, routed_providers_by_owner_and_id)
          )
        elsif run.provider.present?
          run.provider.display_name
        else
          Provider.display_name_for(run.effective_provider)
        end
    end
  end

  def agent_run_provider_display(run, provider_displays = nil)
    return provider_displays.fetch(run.id) if provider_displays

    agent_run_provider_displays([ run ]).fetch(run.id)
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
      display[:emoji],
      title: display[:title] || display[:label],
      class: "inline-flex items-center text-sm",
      aria: { label: display[:label] }
    )
  end

  def issue_lifecycle_legend_tooltip
    legend = ISSUE_LIFECYCLE_DISPLAY.map { |_key, display| "#{display[:emoji]} = #{display[:label]}" }.join("  ·  ")
    tag.span(
      "ℹ️",
      title: legend,
      class: "ml-1 cursor-help text-sm text-gray-400",
      aria: { label: "Status legend" }
    )
  end

  GITHUB_PRIORITY_LABEL_STYLES = {
    "P0" => "bg-red-700 text-red-50",
    "P1" => "bg-red-100 text-red-800",
    "P2" => "bg-orange-100 text-orange-800",
    "P3" => "bg-blue-100 text-blue-800"
  }.freeze

  DEFAULT_ISSUE_LABEL_STYLE = "bg-gray-100 text-gray-600"

  def issue_label_badge_classes(project, label)
    priority_tier = priority_tier_for_label(project, label)
    styles = GITHUB_PRIORITY_LABEL_STYLES.fetch(priority_tier, DEFAULT_ISSUE_LABEL_STYLE)
    "inline-flex items-center rounded-full px-2 py-0.5 text-xs #{styles}"
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

  def project_member_path(project)
    app_route_path(:project_path, project)
  end

  def project_agent_run_member_path(project, agent_run)
    app_route_path(:project_agent_run_path, project, agent_run)
  end

  def project_agent_runs_collection_path(project)
    app_route_path(:project_agent_runs_path, project)
  end

  def new_project_agent_run_member_path(project)
    app_route_path(:new_project_agent_run_path, project)
  end

  def cleanup_stale_runs_project_member_path(project)
    app_route_path(:cleanup_stale_runs_project_path, project)
  end

  def dashboard_cancel_agent_run_member_path(agent_run)
    app_route_path(:dashboard_cancel_run_path, agent_run)
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
    elsif run.enhance_issue_goal?
      enhance_issue_context(run)
    elsif run.analyze_issue_goal?
      analyze_issue_context(run)
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

  REVIEW_METHOD_STYLES = {
    "codex" => { bg: "bg-amber-100", text: "text-amber-700", label: "Codex" },
    "manual" => { bg: "bg-sky-100", text: "text-sky-700", label: "Manual" },
    "copilot" => { bg: "bg-blue-100", text: "text-blue-700", label: "GitHub Copilot" },
    "paid_agent" => { bg: "bg-purple-100", text: "text-purple-700", label: "Paid Agent" },
    "ci_action" => { bg: "bg-teal-100", text: "text-teal-700", label: "CI Action" }
  }.freeze

  # Validate at load time that every Project::REVIEW_METHODS entry has a style defined.
  # This catches drift immediately rather than silently rendering missing badges.
  Rails.application.config.after_initialize do
    missing = Project::REVIEW_METHODS - REVIEW_METHOD_STYLES.keys
    if missing.any?
      if Rails.env.local?
        raise "REVIEW_METHOD_STYLES is missing keys: #{missing}"
      else
        Rails.logger.error(message: "REVIEW_METHOD_STYLES is missing keys", missing: missing)
      end
    end
  end

  def review_method_badge(method)
    styles = REVIEW_METHOD_STYLES[method]
    unless styles
      Rails.logger.warn { "review_method_badge: unknown method #{method.inspect}" }
      return
    end

    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
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
    tooltip_id = "context_#{run.id}"
    inner = case context[:type]
    when :link
      tooltip_data = context[:tooltip].present? ? { action: "focusin->tooltip#show" } : {}
      aria_attrs = context[:tooltip].present? ? { describedby: tooltip_id } : {}
      link_to(context[:label], context[:url], target: "_blank", rel: "noopener noreferrer",
        class: "text-indigo-600 hover:text-indigo-900", title: context[:tooltip],
        aria: aria_attrs.presence, data: tooltip_data.presence)
    when :text
      tooltip_data = context[:tooltip].present? ? { action: "focusin->tooltip#show" } : {}
      aria_attrs = context[:tooltip].present? ? { describedby: tooltip_id } : {}
      tag.span(context[:label], class: context[:classes], title: context[:tooltip],
        tabindex: (context[:tooltip].present? ? "0" : nil),
        aria: aria_attrs.presence, data: tooltip_data.presence)
    when :in_progress
      tag.span("Creating issue\u2026", class: "italic text-gray-500")
    else
      tag.span("-", class: "text-gray-400")
    end

    mobile_tooltip_wrapper(inner, context[:tooltip], tooltip_id, aria_label: "Show context details")
  end

  AGENT_RUN_GOAL_LABEL_OVERRIDES = {
    "create_pr" => "PR Creation",
    "create_issue" => "Issue Creation",
    "review" => "Code Review"
  }.freeze

  AGENT_RUN_GOAL_LABELS = AgentRun::GOALS.index_with do |goal|
    AGENT_RUN_GOAL_LABEL_OVERRIDES.fetch(goal, goal.to_s.titleize)
  end.freeze

  def agent_run_goal_display(run)
    text = agent_run_goal_text(run)
    return tag.span("-", class: "text-gray-400") if text.blank?

    inner = tag.span(text, class: "min-w-0 block truncate", title: text)
    tooltip_id = "goal_#{run.id || run.object_id}"

    mobile_tooltip_wrapper(inner, text, tooltip_id, aria_label: "Show goal details")
  end

  def agent_run_goal_text(run)
    AGENT_RUN_GOAL_LABELS.fetch(run.goal, run.goal.to_s.titleize)
  end

  # Returns the best "back" URL: checks params[:return_to] first, then
  # request.referer, then falls back to the provided default path.
  # Only internal (same-host, path-only) URLs are accepted to prevent open redirects.
  def back_link_path(default_path)
    return_to = params[:return_to]
    if return_to.present? && safe_return_path?(return_to)
      return_to
    elsif request.referer.present? && safe_referer?(request.referer)
      request.referer
    else
      default_path
    end
  end

  # Redacts potential secrets from error messages before displaying them in the UI.
  # Uses the Knowledge::Redaction::Redactor for consistent secret detection.
  def redacted_error_message(message)
    return nil if message.blank?

    Knowledge::Redaction::Redactor.call(text: message).clean_text
  end

  def provider_attempt_diagnostics_summary(attempt)
    diagnostics = attempt["diagnostics"]
    return nil unless diagnostics.is_a?(Hash)

    summary = []
    summary << "#{diagnostics['timeout_type'].to_s.humanize} timeout" if diagnostics["timeout_type"].present?
    summary << "elapsed #{number_with_precision(diagnostics['elapsed_seconds'], precision: 1)}s" if diagnostics["elapsed_seconds"].present?
    summary << "idle #{number_with_precision(diagnostics['idle_seconds'], precision: 1)}s" if diagnostics["idle_seconds"].present?
    summary << "limit #{number_with_precision(diagnostics['effective_timeout_seconds'], precision: 0)}s" if diagnostics["effective_timeout_seconds"].present?
    summary << "heartbeat active" if diagnostics["heartbeat_active"]
    summary << "no output" if diagnostics["output_received"] == false
    summary.presence&.join(" • ")
  end

  private

  def create_pr_context(run)
    if run.issue.present?
      prefix = run.issue.is_pull_request? ? "PR" : "Issue"
      label = "#{prefix} ##{run.issue.github_number}"
      github_link_or_text(label, label, run.issue.github_url, tooltip: run.issue.title)
    elsif run.source_pull_request_number.present?
      url = source_pull_request_url(run)
      label = "PR ##{run.source_pull_request_number}"
      github_link_or_text(label, label, url)
    elsif run.pull_request_number.present?
      github_link_or_text("PR ##{run.pull_request_number}", "PR ##{run.pull_request_number}", run.pull_request_url)
    elsif run.custom_prompt.present?
      redacted = redacted_goal_text(run.custom_prompt)
      if redacted.present?
        { type: :text, label: redacted.truncate(60), classes: "text-gray-700", tooltip: redacted }
      else
        { type: :placeholder }
      end
    else
      { type: :placeholder }
    end
  end

  def redacted_goal_text(text)
    normalized = text.to_s.squish
    return nil if normalized.blank?

    Knowledge::Redaction::Redactor.call(text: normalized).clean_text.presence
  end

  def create_issue_context(run)
    if safe_github_url?(run.created_issue_url)
      label = run.created_issue_number.present? ? "Issue ##{run.created_issue_number}" : "Issue"
      { type: :link, label: label, url: run.created_issue_url }
    elsif run.custom_prompt.present?
      redacted = redacted_goal_text(run.custom_prompt)
      if redacted.present?
        { type: :text, label: redacted.truncate(60), classes: "text-gray-700", tooltip: redacted }
      else
        { type: :placeholder }
      end
    elsif !run.finished?
      { type: :in_progress }
    else
      { type: :placeholder }
    end
  end

  def review_context(run)
    if run.source_pull_request_number.present?
      url = source_pull_request_url(run)
      label = "PR ##{run.source_pull_request_number}"
      github_link_or_text(label, label, url)
    else
      { type: :placeholder }
    end
  end

  def enhance_issue_context(run)
    if run.issue.present?
      label = "Issue ##{run.issue.github_number}"
      github_link_or_text(label, label, run.issue.github_url, tooltip: run.issue.title)
    else
      { type: :placeholder }
    end
  end

  # analyze_issue and enhance_issue share the same context rendering: link to
  # the associated issue when present, placeholder otherwise.
  alias_method :analyze_issue_context, :enhance_issue_context

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

  # Wraps content with a mobile-friendly info-icon tooltip using the Stimulus
  # tooltip controller. Desktop users see the native title attribute; on touch
  # devices the icon toggles a popover. Returns +inner+ unchanged when
  # +tooltip_text+ is blank.
  def mobile_tooltip_wrapper(inner, tooltip_text, dom_id, aria_label: "Show details")
    return inner if tooltip_text.blank?

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
          aria: { label: aria_label, describedby: dom_id, expanded: "false", controls: dom_id }
        ),
        tag.span(
          tooltip_text,
          id: dom_id,
          role: "tooltip",
          aria: { hidden: "true" },
          class: "hidden fixed z-50 w-48 rounded bg-gray-900 px-2 py-1 text-xs text-white shadow-lg",
          data: { tooltip_target: "content" }
        )
      ])
    end
  end

  def github_link_or_text(link_label, text_label, url, tooltip: nil)
    if safe_github_url?(url)
      { type: :link, label: link_label, url: url, tooltip: tooltip }
    else
      { type: :text, label: text_label, classes: "text-gray-700", tooltip: tooltip }
    end
  end

  def source_pull_request_url(run)
    return nil unless run.source_pull_request_number.present? && run.project.present?

    "#{run.project.github_url}/pull/#{run.source_pull_request_number}"
  end

  def provider_display_for_identifier(identifier, provider: nil)
    return provider.display_name if provider
    return MISSING_PROVIDER_ENTRY_LABEL if Provider.routing_key?(identifier)

    Provider.display_name_for(normalized_provider_identifier(identifier))
  end

  def provider_for_identifier(run, configured_providers_by_owner_and_key, routed_providers_by_owner_and_id)
    if Provider.routing_key?(run.final_provider)
      owner_id = run.project&.effective_owner&.id
      provider_id = Provider.id_from_routing_key(run.final_provider)
      return routed_providers_by_owner_and_id[[ owner_id, provider_id ]]
    end

    normalized_identifier = normalized_provider_identifier(run.final_provider)

    configured_providers_by_owner_and_key[[ run.project&.effective_owner&.id, normalized_identifier ]] ||
      (run.provider if run.provider&.matches_identifier?(run.final_provider))
  end

  def routed_providers_for_runs(runs)
    provider_ids_by_owner_id = runs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |run, provider_ids|
      next unless Provider.routing_key?(run.final_provider)

      owner_id = run.project&.effective_owner&.id
      provider_id = Provider.id_from_routing_key(run.final_provider)
      next unless owner_id && provider_id

      provider_ids[owner_id] << provider_id
    end
    return {} if provider_ids_by_owner_id.empty?

    Provider.with_discarded.where(user_id: provider_ids_by_owner_id.keys, id: provider_ids_by_owner_id.values.flatten.uniq)
      .index_by { |provider| [ provider.user_id, provider.id ] }
  end

  def configured_providers_for_runs(runs)
    owner_ids_by_provider_key = runs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |run, provider_keys|
      next if run.final_provider.blank? || Provider.routing_key?(run.final_provider)

      owner_id = run.project&.effective_owner&.id
      next unless owner_id

      provider_keys[normalized_provider_identifier(run.final_provider)] << owner_id
    end
    return {} if owner_ids_by_provider_key.empty?

    Provider.with_discarded.where(
      user_id: owner_ids_by_provider_key.values.flatten.uniq,
      provider_key: owner_ids_by_provider_key.keys
    ).ordered.group_by { |provider| [ provider.user_id, provider.provider_key ] }
      .transform_values { |providers| providers.find(&:subscription?) || providers.first }
  end

  def safe_asset_tag
    yield
  rescue Propshaft::MissingAssetError
    raise unless Rails.env.test?
  end

  def normalized_provider_identifier(identifier)
    ProviderSupport.provider_key_for_agent_type(identifier)
  end

  def app_route_path(name, *args, **kwargs)
    return public_send(name, *args, **kwargs) if respond_to?(name)

    Rails.application.routes.url_helpers.public_send(name, *args, **kwargs)
  end

  def safe_return_path?(path)
    path.start_with?("/") && !path.start_with?("//")
  end

  def safe_referer?(url)
    uri = URI.parse(url)
    uri.host == request.host
  rescue URI::InvalidURIError
    false
  end

  def priority_tier_for_label(project, label)
    return "P0" if label == "P0"
    return if project.blank?

    Project::PRIORITY_TIERS.find do |tier|
      label == project.priority_label_for(tier)
    end
  end
end
