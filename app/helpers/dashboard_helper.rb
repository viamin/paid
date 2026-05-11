# frozen_string_literal: true

module DashboardHelper
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

  GOAL_LABELS = {
    "create_pr" => "PR Creation",
    "create_issue" => "Issue Creation",
    "review" => "Code Review"
  }.freeze

  OUTCOME_LABELS = {
    "completed" => "Successful",
    "other" => "Other (Failed/Timeout/etc.)"
  }.freeze

  def goal_label(goal)
    GOAL_LABELS.fetch(goal, goal.to_s.titleize)
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
    "applied" => "bg-emerald-100 text-emerald-700",
    "noop" => "bg-amber-100 text-amber-700",
    "failed" => "bg-rose-100 text-rose-700"
  }.freeze

  DECISION_STATUS_BAR_CLASSES = {
    "applied" => "bg-emerald-500",
    "noop" => "bg-amber-500",
    "failed" => "bg-rose-500"
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
end
