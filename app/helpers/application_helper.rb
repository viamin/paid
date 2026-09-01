# frozen_string_literal: true

module ApplicationHelper
  ESCALATION_REASON_LABELS = {
    "failure_streak" => "Failure streak",
    "review_goal_retry_limit" => "Retry limit",
    "pr_auto_continue_token_limit" => "Token cap",
    "operational_failures" => "Infrastructure failures",
    "awaiting_approval" => "Awaiting approval"
  }.freeze

  ESCALATION_COUNTER_LABELS = {
    draft_review_count: "Draft rounds",
    pr_followup_count: "Follow-up runs",
    review_goal_retry_count: "Review retries"
  }.freeze

  def escalation_reason_label(reason)
    ESCALATION_REASON_LABELS.fetch(reason.to_s, "Stopped")
  end

  # The Unblock confirmation names what clearing does. For an
  # awaiting_approval escalation no counters were tripped and no token cap is
  # waived — the generic agent-failure wording would be misleading.
  # @spec PR-ESCALATION-026
  def unblock_confirmation_text(entry)
    pr = entry.pull_request
    if entry.reason == Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL
      return "Clear the escalation on #{pr.project.full_name}##{pr.github_number}? " \
             "Approving the PR also clears it — unblocking alone just returns it to the scanner."
    end

    "Clear the escalation on #{pr.project.full_name}##{pr.github_number}? " \
      "This resets its attempt counters, waives the token cap for this PR, and returns it to the scanner."
  end

  def escalation_counter_label(name)
    ESCALATION_COUNTER_LABELS.fetch(name.to_sym, name.to_s.humanize)
  end
  MISSING_RUNNER_ENTRY_LABEL = "Deleted runner entry"
  MISSING_PROVIDER_ENTRY_LABEL = MISSING_RUNNER_ENTRY_LABEL

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
    "token_budget_exceeded" => { bg: "bg-rose-100", text: "text-rose-700", label: "Token Budget Exceeded" },
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

  def agent_run_display_duration_seconds(agent_run)
    duration_seconds = agent_run.respond_to?(:duration_seconds) ? agent_run.duration_seconds : nil
    return duration_seconds if duration_seconds.present?

    started_at = agent_run.respond_to?(:started_at) ? agent_run.started_at : nil
    paused_at = agent_run.respond_to?(:paused_at) ? agent_run.paused_at : nil
    if paused_at.present? && started_at.present?
      return [ (paused_at - started_at).to_i, 0 ].max
    end

    if agent_run.respond_to?(:running?) && agent_run.running?
      duration = agent_run.respond_to?(:duration) ? agent_run.duration : nil
      return duration if duration.present?
    end

    completed_at = agent_run.respond_to?(:completed_at) ? agent_run.completed_at : nil
    return nil unless completed_at.present?

    created_at = agent_run.respond_to?(:created_at) ? agent_run.created_at : nil
    start_time = started_at || created_at
    return nil unless start_time.present?

    [ (completed_at - start_time).to_i, 0 ].max
  end

  # Extracts the persisted egress policy snapshot recorded on the run before
  # provisioning. Delegates to AgentRun#egress_policy_snapshot so controllers
  # and views share a single extraction of the authoritative snapshot.
  def agent_run_egress_policy_snapshot(agent_run)
    agent_run.egress_policy_snapshot
  end

  EGRESS_DESTINATION_SOURCE_KIND_BADGES = {
    "platform" => "bg-indigo-100 text-indigo-700",
    "tenant" => "bg-amber-100 text-amber-700",
    "tenant_account" => "bg-amber-100 text-amber-700",
    "tenant_project" => "bg-emerald-100 text-emerald-700",
    "service_container" => "bg-sky-100 text-sky-700",
    "preview_tunnel" => "bg-violet-100 text-violet-700"
  }.freeze

  def source_kind_badge_classes(kind)
    EGRESS_DESTINATION_SOURCE_KIND_BADGES[kind.to_s] || "bg-gray-100 text-gray-700"
  end

  AGENT_RUN_PRIORITY_STYLES = { # @spec QUEUE-TIER-004
    manual: { bg: "bg-sky-100", text: "text-sky-700" },
    pr_p1: { bg: "bg-red-100", text: "text-red-700" },
    pr_p2: { bg: "bg-orange-100", text: "text-orange-700" },
    pr_p3: { bg: "bg-amber-100", text: "text-amber-700" },
    pr_continue: { bg: "bg-violet-100", text: "text-violet-700" },
    issue_p1: { bg: "bg-red-100", text: "text-red-700" },
    issue_p2: { bg: "bg-orange-100", text: "text-orange-700" },
    issue_p3: { bg: "bg-amber-100", text: "text-amber-700" },
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

  def agent_run_runner_displays(runs)
    runs = runs.to_a
    routed_runners_by_owner_and_id = routed_runners_for_runs(runs)
    configured_runners_by_owner_and_key = configured_runners_for_runs(runs)

    runs.each_with_object({}) do |run, displays|
      current_runner = current_runner_record(run)
      final_runner = run.respond_to?(:final_runner) ? run.final_runner : nil
      effective_runner = run.respond_to?(:effective_runner) ? run.effective_runner : nil
      displays[run.id] =
        if final_runner.present?
          runner_display_for_identifier(
            final_runner,
            runner: runner_for_identifier(run, configured_runners_by_owner_and_key, routed_runners_by_owner_and_id)
          )
        elsif current_runner.present?
          current_runner.display_name
        else
          Runner.display_name_for(effective_runner)
        end
    end
  end

  def agent_run_runner_display(run, runner_displays = nil)
    return runner_displays.fetch(run.id) if runner_displays

    agent_run_runner_displays([ run ]).fetch(run.id)
  end

  def agent_run_provider_displays(runs)
    agent_run_runner_displays(runs)
  end

  def agent_run_provider_display(run, provider_displays = nil)
    agent_run_runner_display(run, provider_displays)
  end

  PAID_STATE_STYLES = {
    "new" => { bg: "bg-gray-100", text: "text-gray-700", label: "New" },
    "planning" => { bg: "bg-purple-100", text: "text-purple-700", label: "Planning" },
    "in_progress" => { bg: "bg-blue-100", text: "text-blue-700", label: "In Progress" },
    "completed" => { bg: "bg-green-100", text: "text-green-700", label: "Completed" },
    "failed" => { bg: "bg-red-100", text: "text-red-700", label: "Failed" },
    "needs_input" => { bg: "bg-amber-100", text: "text-amber-700", label: "Needs Input" },
    "manual_review" => { bg: "bg-orange-100", text: "text-orange-700", label: "Manual Review" },
    "recommend_close" => { bg: "bg-orange-100", text: "text-orange-700", label: "Recommend Close" }
  }.freeze

  def paid_state_badge(state)
    styles = PAID_STATE_STYLES[state] || PAID_STATE_STYLES["new"]
    tag.span(
      styles[:label],
      class: "inline-flex items-center rounded-md #{styles[:bg]} px-2 py-1 text-xs font-medium #{styles[:text]}"
    )
  end

  # Badge for a PR's position in the review -> merge gate. Driven by
  # Issue#pr_review_phase, the same field that drives the paid-ready /
  # paid-escalated / paid-auto-merged GitHub labels, so the project page badge
  # tracks GitHub readiness rather than "the agent finished a run" (paid_state).
  PR_REVIEW_PHASE_STYLES = {
    "draft" => { bg: "bg-blue-100", text: "text-blue-700", label: "In Review" },
    "restarted" => { bg: "bg-blue-100", text: "text-blue-700", label: "In Review" },
    "ready" => { bg: "bg-green-100", text: "text-green-700", label: "Ready" },
    "escalated" => { bg: "bg-orange-100", text: "text-orange-700", label: "Escalated" },
    "merged" => { bg: "bg-purple-100", text: "text-purple-700", label: "Merged" }
  }.freeze

  def pr_review_phase_badge(phase, review_count: nil)
    styles = PR_REVIEW_PHASE_STYLES[phase] || PR_REVIEW_PHASE_STYLES["draft"]
    title = review_count.to_i.positive? ? pluralize(review_count, "review round") : nil
    tag.span(
      styles[:label],
      title: title,
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

  # Confirmation copy for the pause toggle. Issue auto-pick is gated by
  # `paused`, but PR review/escalation automation is not yet gated (see the
  # AddPausedToIssues migration comment), so the PR copy must not promise that
  # automation will stop.
  def issue_pause_confirm_message(issue)
    kind = issue_kind_label(issue, style: :short_lower)
    number = issue.github_number
    label = Issue::PAUSED_LABEL
    if issue.is_pull_request?
      "Pause #{kind} ##{number}? Adds a #{label} label on GitHub. PR review automation is not yet gated by pause."
    else
      "Pause #{kind} ##{number}? Automation will skip it and a #{label} label is added on GitHub."
    end
  end

  def issue_lifecycle_legend_tooltip
    legend = ISSUE_LIFECYCLE_DISPLAY.map { |_key, display| "#{display[:emoji]} = #{display[:label]}" }.join("  ·  ")
    tag.span(
      "\u{2139}\u{FE0F}",
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

  # Resolves trace viewer data ({ available:, embed_url: }) for an agent run.
  #
  # A trace is keyed by the run's repo/PR/result commit. Availability is only
  # checked once the run is finished (a running run has no recorded trace yet),
  # and only when trace storage is configured, so this never makes S3 calls
  # during active runs and degrades to "unavailable" on any error.
  #
  # @return [Hash{Symbol => Boolean,String}] with :available and :embed_url keys.
  def agent_run_trace_viewer_data(agent_run)
    return { available: false, embed_url: nil } unless agent_run.respond_to?(:project)

    project = agent_run.project
    return { available: false, embed_url: nil } unless project&.owner && project&.repo

    pr_number = agent_run.try(:pull_request_number)
    commit_sha = agent_run.try(:result_commit_sha).presence || agent_run.try(:base_commit_sha)
    return { available: false, embed_url: nil } unless pr_number.present? && commit_sha.present?

    viewer = Previews::TraceViewer.new
    return { available: false, embed_url: nil } unless viewer.configured?

    unless agent_run.respond_to?(:finished?) && agent_run.finished?
      return { available: false, embed_url: nil }
    end

    params = { org: project.owner, repo: project.repo, pr_number: pr_number, commit_sha: commit_sha }
    available = viewer.trace_available?(**params)
    embed_url = available ? viewer.embed_url(**params) : nil
    { available: available, embed_url: embed_url }
  rescue StandardError
    { available: false, embed_url: nil }
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

  def project_type_badge(project)
    label = project.project_type_label
    return unless label

    tag.span(
      label,
      class: "inline-flex items-center rounded-md bg-indigo-100 px-2 py-1 text-xs font-medium text-indigo-700",
      title: project.primary_language
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
      link_to(context[:label], context[:url], target: "_blank", rel: "noopener noreferrer",
        class: "text-indigo-600 hover:text-indigo-900", title: context[:tooltip])
    when :text
      tag.span(context[:label], class: context[:classes], title: context[:tooltip],
        tabindex: (context[:tooltip].present? ? "0" : nil))
    when :in_progress
      tag.span("Creating issue\u2026", class: "italic text-gray-500")
    else
      tag.span("-", class: "text-gray-400")
    end

    mobile_tooltip_wrapper(inner, context[:tooltip], tooltip_id, aria_label: "Show context details")
  end

  AGENT_RUN_GOAL_LABELS = {
    "create_pr" => "PR Creation",
    "create_issue" => "Issue Creation",
    "review" => "Code Review",
    "enhance_issue" => "Issue Enhancement",
    "analyze_issue" => "Issue Analysis",
    "lid_planning" => "LID Planning",
    "create_feature" => "Feature Creation"
  }.freeze

  AGENT_RUN_FOCUS_LABELS = {
    "ci_fix" => "CI Fix",
    "review_feedback" => "Review Feedback",
    "merge_conflict" => "Merge Conflict",
    "conversation" => "Conversation",
    "issue_implementation" => "Issue Implementation",
    "label_action" => "Label Action"
  }.freeze

  AGENT_RUN_FOCUS_BADGE_CLASSES = {
    "ci_fix" => "bg-rose-100 text-rose-700",
    "review_feedback" => "bg-violet-100 text-violet-700",
    "merge_conflict" => "bg-amber-100 text-amber-700",
    "conversation" => "bg-sky-100 text-sky-700",
    "issue_implementation" => "bg-emerald-100 text-emerald-700",
    "label_action" => "bg-teal-100 text-teal-700"
  }.freeze

  def agent_run_goal_display(run)
    text = agent_run_goal_text(run)
    return tag.span("-", class: "text-gray-400") if text.blank?

    tag.span(text, class: "min-w-0 block truncate")
  end

  def agent_run_goal_text(run)
    AGENT_RUN_GOAL_LABELS.fetch(run.goal, run.goal.to_s.titleize)
  end

  # Renders the work-type focus badge for an agent run, shown only when the
  # run is focused (focus != "general"). Most runs are general, so this stays
  # out of the way and surfaces the distinction only where it actually answers
  # "why is this run different?" — e.g. PR follow-up runs addressing review
  # comments (focus: review_feedback) vs. fresh-issue PR runs (focus: general).
  def agent_run_focus_badge(run)
    focus = run.respond_to?(:focus) ? run.focus.to_s : ""
    return nil if focus.blank? || focus == "general"

    label = AGENT_RUN_FOCUS_LABELS.fetch(focus, focus.tr("_", " ").titleize)
    classes = AGENT_RUN_FOCUS_BADGE_CLASSES.fetch(focus, "bg-slate-100 text-slate-700")
    tag.span(label,
      class: "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium #{classes}",
      title: "Work type: #{label}")
  end

  # Destination for a "Back to X" link. Deterministic by default: the link
  # navigates to +default_path+ (the page its label names), so a link labeled
  # "Back to Projects" always lands on the projects index. An explicit,
  # same-host params[:return_to] is still honored when a controller sets one
  # intentionally (e.g. deep-linking back into a project after a sub-flow).
  # Only internal (path-only) URLs are accepted to prevent open redirects.
  #
  # The previous request.referer fallback was removed because it routed users
  # to whatever page they happened to arrive from, so "Back to Projects" could
  # land on the Dashboard (or anywhere) — the link never did what its label
  # promised.
  def back_link_path(default_path)
    return_to = params[:return_to].to_s if params[:return_to].present?
    (return_to.present? && safe_return_path?(return_to)) ? return_to : default_path
  end

  def safe_return_path_or(path, fallback)
    safe_return_path?(path.to_s) ? path : fallback
  end

  # Redacts potential secrets from error messages before displaying them in the UI.
  # Uses the Knowledge::Redaction::Redactor for consistent secret detection.
  def redacted_error_message(message)
    return nil if message.blank?

    Knowledge::Redaction::Redactor.call(text: message).clean_text
  end

  def runner_attempt_diagnostics_summary(attempt)
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
      github_link_or_text(label, label, run.issue.github_url, tooltip: run.issue.title.presence || label)
    elsif run.source_pull_request_number.present?
      url = source_pull_request_url(run)
      label = "PR ##{run.source_pull_request_number}"
      github_link_or_text(label, label, url, tooltip: source_pull_request_tooltip(run) || label)
    elsif run.pull_request_number.present?
      label = "PR ##{run.pull_request_number}"
      github_link_or_text(label, label, run.pull_request_url, tooltip: label)
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
      { type: :link, label: label, url: run.created_issue_url, tooltip: created_issue_tooltip(run) || label }
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
      github_link_or_text(label, label, url, tooltip: source_pull_request_tooltip(run) || label)
    else
      { type: :placeholder }
    end
  end

  def enhance_issue_context(run)
    if run.issue.present?
      label = "Issue ##{run.issue.github_number}"
      github_link_or_text(label, label, run.issue.github_url, tooltip: run.issue.title.presence || label)
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

  # Wraps content with a mobile-friendly info-icon tooltip using CSS-only details.
  # Desktop users see the native title attribute; on touch devices the icon toggles
  # a popover. Returns +inner+ unchanged when +tooltip_text+ is blank.
  def mobile_tooltip_wrapper(inner, tooltip_text, dom_id, aria_label: "Show details")
    return inner if tooltip_text.blank?

    tag.details(class: "inline-flex items-center gap-1 group relative") do
      safe_join([
        tag.summary(
          tag.svg(
            tag.path(d: "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"),
            class: "h-4 w-4", fill: "none", viewBox: "0 0 24 24", stroke: "currentColor",
            "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
            aria: { hidden: "true" }, focusable: "false"
          ),
          class: "[@media(hover:hover)_and_(pointer:fine)_and_(not_(any-pointer:coarse))]:hidden cursor-pointer text-gray-400 hover:text-gray-600 list-none",
          aria: { label: aria_label }
        ),
        inner,
        tag.span(
          tooltip_text,
          id: dom_id,
          role: "tooltip",
          class: "hidden group-open:block fixed z-50 w-48 rounded bg-gray-900 px-2 py-1 text-xs text-white shadow-lg"
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

  def source_pull_request_tooltip(run)
    issue_title_for(run, github_number: run.source_pull_request_number, is_pull_request: true)
  end

  def created_issue_tooltip(run)
    issue_title_for(run, github_number: run.created_issue_number, is_pull_request: false)
  end

  def issue_title_for(run, github_number:, is_pull_request:)
    return nil if github_number.blank?

    if is_pull_request && run.respond_to?(:source_pull_request_record)
      title = run.source_pull_request_record&.title
      return title if title.present?

      return nil
    end

    if !is_pull_request && run.respond_to?(:created_issue_record)
      title = run.created_issue_record&.title
      return title if title.present?

      return nil
    end

    nil
  end

  def runner_display_for_identifier(identifier, runner: nil)
    return runner.display_name if runner
    return MISSING_RUNNER_ENTRY_LABEL if Runner.routing_key?(identifier)

    Runner.display_name_for(normalized_runner_identifier(identifier))
  end

  def runner_for_identifier(run, configured_runners_by_owner_and_key, routed_runners_by_owner_and_id)
    final_runner = run.respond_to?(:final_runner) ? run.final_runner : nil

    if Runner.routing_key?(final_runner)
      owner_id = run.respond_to?(:project) ? run.project&.effective_owner&.id : nil
      runner_id = Runner.id_from_routing_key(final_runner)
      return routed_runners_by_owner_and_id[[ owner_id, runner_id ]]
    end

    normalized_identifier = normalized_runner_identifier(final_runner)
    current_runner = current_runner_record(run)
    owner_id = run.respond_to?(:project) ? run.project&.effective_owner&.id : nil

    configured_runners_by_owner_and_key[[ owner_id, normalized_identifier ]] ||
      (current_runner if current_runner&.matches_identifier?(final_runner))
  end

  def routed_runners_for_runs(runs)
    runner_ids_by_owner_id = runs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |run, runner_ids|
      final_runner = run.respond_to?(:final_runner) ? run.final_runner : nil
      next unless Runner.routing_key?(final_runner)

      owner_id = run.respond_to?(:project) ? run.project&.effective_owner&.id : nil
      runner_id = Runner.id_from_routing_key(final_runner)
      next unless owner_id && runner_id

      runner_ids[owner_id] << runner_id
    end
    return {} if runner_ids_by_owner_id.empty?

    Runner.with_discarded.where(user_id: runner_ids_by_owner_id.keys, id: runner_ids_by_owner_id.values.flatten.uniq)
      .index_by { |runner| [ runner.user_id, runner.id ] }
  end

  def configured_runners_for_runs(runs)
    owner_ids_by_runner_key = runs.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |run, runner_keys|
      final_runner = run.respond_to?(:final_runner) ? run.final_runner : nil
      next if final_runner.blank? || Runner.routing_key?(final_runner)

      owner_id = run.respond_to?(:project) ? run.project&.effective_owner&.id : nil
      next unless owner_id

      runner_keys[normalized_runner_identifier(final_runner)] << owner_id
    end
    return {} if owner_ids_by_runner_key.empty?

    Runner.with_discarded.where(
      user_id: owner_ids_by_runner_key.values.flatten.uniq,
      runner_key: owner_ids_by_runner_key.keys
    ).ordered.group_by { |runner| [ runner.user_id, runner.runner_key ] }
      .transform_values { |runners| runners.find(&:subscription?) || runners.first }
  end

  def current_runner_record(run)
    if run.respond_to?(:association)
      return run.provider if run.association(:provider).loaded?
      return run.runner if run.association(:runner).loaded?
    end

    return run.runner if run.respond_to?(:runner)
    return run.provider if run.respond_to?(:provider)

    nil
  end

  def safe_asset_tag
    yield
  rescue Propshaft::MissingAssetError
    raise unless Rails.env.test?
  end

  def normalized_runner_identifier(identifier)
    RunnerSupport.runner_key_for_agent_type(identifier)
  end

  def app_route_path(name, *args, **kwargs)
    return public_send(name, *args, **kwargs) if respond_to?(name)
    return main_app.public_send(name, *args, **kwargs) if respond_to?(:main_app) && main_app.respond_to?(name)

    if respond_to?(:_routes_context, true)
      routes_context = _routes_context
      return routes_context.public_send(name, *args, **kwargs) if routes_context.respond_to?(name)
    end

    if respond_to?(:_routes, true)
      route_helpers = _routes.url_helpers
      return route_helpers.public_send(name, *args, **kwargs) if route_helpers.respond_to?(name)
    end

    Rails.application.routes.url_helpers.public_send(name, *args, **kwargs)
  end

  def safe_return_path?(path)
    return false if path.blank?

    path = path.to_s
    return false unless path.start_with?("/") && !path.start_with?("//")

    safe_url_from(path).present?
  end

  def priority_tier_for_label(project, label)
    return "P0" if label == "P0"
    return if project.blank?

    Project::PRIORITY_TIERS.find do |tier|
      label == project.priority_label_for(tier)
    end
  end

  def safe_url_from(url)
    return unless respond_to?(:controller) && controller.respond_to?(:url_from)

    controller.url_from(url)
  rescue URI::InvalidURIError
    nil
  end
end
