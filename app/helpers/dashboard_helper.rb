# frozen_string_literal: true

module DashboardHelper
  INBOX_PR_BADGE_CLASSES = "bg-purple-100 text-purple-700".freeze
  INBOX_ISSUE_BADGE_CLASSES = "bg-slate-100 text-slate-700".freeze

  PHASE_GROUP_LABELS = {
    "queue" => "Queue",
    "setup" => "Setup",
    "prompt" => "Prompt Prep",
    "agent" => "Agent",
    "post" => "Post-Processing",
    "cleanup" => "Cleanup"
  }.freeze

  PHASE_GROUP_BAR_STYLES = {
    "queue" => "bg-slate-400",
    "setup" => "bg-sky-500",
    "prompt" => "bg-violet-500",
    "agent" => "bg-emerald-500",
    "post" => "bg-amber-500",
    "cleanup" => "bg-rose-400"
  }.freeze

  def format_duration(seconds)
    return "--" unless seconds
    return "0s" if seconds.zero?

    if seconds >= 86400
      "#{seconds / 86400}d #{(seconds % 86400) / 3600}h"
    elsif seconds >= 3600
      "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
    elsif seconds >= 60
      "#{seconds / 60}m #{seconds % 60}s"
    else
      "#{seconds}s"
    end
  end

  def phase_group_label(phase_group)
    PHASE_GROUP_LABELS.fetch(phase_group, phase_group.to_s.titleize)
  end

  def phase_group_bar_style(phase_group)
    PHASE_GROUP_BAR_STYLES.fetch(phase_group, "bg-gray-400")
  end

  OUTCOME_LABELS = {
    "completed" => "Successful",
    "other" => "Other (Failed/Timeout/etc.)"
  }.freeze

  def goal_label(goal)
    ApplicationHelper::AGENT_RUN_GOAL_LABELS.fetch(goal, goal.to_s.titleize)
  end

  def outcome_label(outcome)
    OUTCOME_LABELS.fetch(outcome, outcome.to_s.titleize)
  end

  TIME_RANGE_LABELS = {
    "cumulative" => "Cumulative",
    "30d" => "Past 30 Days",
    "7d" => "Past Week",
    "24h" => "Past 24 Hours"
  }.freeze

  STATUS_FILTER_LABELS = {
    "all" => "All Runs",
    "completed" => "Successful",
    "failed" => "Failed"
  }.freeze

  GOAL_FILTER_LABELS = {
    "all" => "All Types",
    "create_issue" => "Issue Creation",
    "create_pr" => "PR Coding",
    "review" => "PR Reviews"
  }.freeze

  DECISION_STATUS_BADGE_CLASSES = {
    "successful" => "bg-emerald-100 text-emerald-700",
    "applied" => "bg-emerald-100 text-emerald-700",
    "noop" => "bg-amber-100 text-amber-700",
    "failed" => "bg-rose-100 text-rose-700"
  }.freeze

  DECISION_STATUS_BAR_CLASSES = {
    "successful" => "bg-emerald-500",
    "applied" => "bg-emerald-500",
    "noop" => "bg-amber-500",
    "failed" => "bg-rose-500"
  }.freeze

  DASHBOARD_CHART_PALETTES = {
    daily_run_status: %w[
      var(--dashboard-chart-danger)
      var(--dashboard-chart-success)
    ],
    outcome_completion_rate: %w[
      var(--dashboard-chart-success)
    ],
    duration_trend: %w[
      var(--dashboard-chart-accent)
      var(--dashboard-chart-success)
      var(--dashboard-chart-muted)
    ],
    pr_cycle_time: %w[
      var(--dashboard-chart-accent)
      var(--dashboard-chart-success)
      var(--dashboard-chart-warning)
    ]
  }.transform_values(&:freeze).freeze

  DASHBOARD_OUTCOME_CHART_COLOR_TOKENS = {
    "completed" => "var(--dashboard-chart-success)",
    "failed" => "var(--dashboard-chart-danger)",
    "timeout" => "var(--dashboard-chart-orange)",
    "token_budget_exceeded" => "var(--dashboard-chart-rose)",
    "no_output" => "var(--dashboard-chart-violet)",
    "auth_expired" => "var(--dashboard-chart-blue)",
    "rate_limited" => "var(--dashboard-chart-warning)",
    "cancelled" => "var(--dashboard-chart-neutral)",
    "retried" => "var(--dashboard-chart-muted)"
  }.freeze

  DASHBOARD_CHART_ANNOTATION_COLORS = {
    border: "var(--dashboard-chart-annotation-border)",
    label_background: "var(--dashboard-chart-annotation-background)",
    label_text: "var(--dashboard-chart-annotation-text)"
  }.freeze

  def time_range_label(range)
    TIME_RANGE_LABELS.fetch(range, range.to_s.titleize)
  end

  def decision_type_label(decision_type)
    return "Uncategorized" if decision_type.to_s == "uncategorized"

    decision_type.to_s.tr("_", " ").titleize
  end

  def decision_status_badge_classes(status)
    DECISION_STATUS_BADGE_CLASSES.fetch(status.to_s, "bg-slate-100 text-slate-700")
  end

  def decision_status_bar_classes(status)
    DECISION_STATUS_BAR_CLASSES.fetch(status.to_s, "bg-slate-400")
  end

  def decision_status_group(status)
    OrchestrationDecision.analytics_status_group(status)
  end

  def decision_status_label(status)
    OrchestrationDecision.normalized_decision_status(status).tr("_", " ").titleize
  end

  # Dark-mode colors for these badges are handled by the global unlayered
  # overrides in application.tailwind.css (e.g. `.dark .bg-green-100`),
  # which have higher cascade priority than Tailwind dark: utilities.
  TIER_BADGE_CLASSES = {
    "low" => "bg-green-100 text-green-700",
    "mid" => "bg-blue-100 text-blue-700",
    "high" => "bg-purple-100 text-purple-700"
  }.freeze

  def tier_badge_classes(tier)
    TIER_BADGE_CLASSES.fetch(tier, "bg-gray-100 text-gray-700")
  end

  def filter_button_classes(active)
    if active
      "inline-flex items-center rounded-md px-3 py-1.5 text-sm font-semibold text-white bg-indigo-600 shadow-sm"
    else
      "inline-flex items-center rounded-md px-3 py-1.5 text-sm font-semibold text-gray-700 bg-white " \
        "ring-1 ring-inset ring-gray-300 hover:bg-gray-50 shadow-sm"
    end
  end

  # @spec DASHBOARD-FILTER-A11Y-001
  def dashboard_filter_link(label, url, active, **link_options)
    aria = link_options.delete(:aria) || {}
    link_to label, url, **link_options, class: filter_button_classes(active), aria: aria.merge(current: active ? "page" : nil)
  end

  # @spec DASHBOARD-CHART-A11Y-010
  def dashboard_chart_colors(key)
    DASHBOARD_CHART_PALETTES.fetch(key)
  end

  # @spec DASHBOARD-CHART-A11Y-010
  def dashboard_outcome_chart_colors(series)
    series.map do |entry|
      status = entry[:name] || entry["name"]
      status = status.to_s.downcase.tr(" ", "_")
      DASHBOARD_OUTCOME_CHART_COLOR_TOKENS.fetch(status, "var(--dashboard-chart-neutral)")
    end
  end

  # @spec DASHBOARD-CHART-A11Y-010
  def chart_annotations(data)
    annotations = {}
    data[:outlier_annotations].each do |date, count|
      annotations["outlier_#{date}"] = {
        type: "line",
        xMin: date.to_s,
        xMax: date.to_s,
        borderColor: DASHBOARD_CHART_ANNOTATION_COLORS[:border],
        borderWidth: 1,
        borderDash: [ 4, 4 ],
        label: {
          display: true,
          content: "#{count} outlier#{count > 1 ? "s" : ""}",
          position: "start",
          backgroundColor: DASHBOARD_CHART_ANNOTATION_COLORS[:label_background],
          color: DASHBOARD_CHART_ANNOTATION_COLORS[:label_text],
          font: { size: 10 }
        }
      }
    end
    annotations
  end

  # @spec OPERATOR-INBOX-007
  def inbox_issue_kind_label(issue)
    issue_kind_label(issue)
  end

  # @spec OPERATOR-INBOX-007
  def inbox_issue_badge_classes(issue)
    issue.is_pull_request? ? INBOX_PR_BADGE_CLASSES : INBOX_ISSUE_BADGE_CLASSES
  end

  # @spec OPERATOR-INBOX-007
  def inbox_issue_link_label(issue)
    "View #{issue_kind_label(issue)}"
  end
end
