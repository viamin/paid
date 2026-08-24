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

  def dashboard_chartkick_chart(chart_type, data_source, **options)
    @dashboard_chartkick_chart_id ||= 0

    element_id = options.delete(:id) || "dashboard-chart-#{@dashboard_chartkick_chart_id += 1}"
    height = (options.delete(:height) || "300px").to_s
    width = (options.delete(:width) || "100%").to_s
    loading = options.delete(:loading) || "Loading..."
    chart_options = options.except(:html, :nonce, :defer, :content_for)
    chart_data = data_source.respond_to?(:chart_json) ? data_source.chart_json : data_source.to_json

    tag.div(
      loading,
      id: element_id,
      style: "height: #{ERB::Util.html_escape(height)}; width: #{ERB::Util.html_escape(width)}; " \
        "text-align: center; color: #999; line-height: #{ERB::Util.html_escape(height)}; " \
        "font-size: 14px; font-family: 'Lucida Grande', 'Lucida Sans Unicode', Verdana, Arial, Helvetica, sans-serif;",
      data: {
        controller: "chartkick",
        chartkick_type_value: chart_type,
        chartkick_data_value: chart_data,
        chartkick_options_value: chart_options.to_json
      }
    )
  end

  def chart_annotations(data)
    annotations = {}
    data[:outlier_annotations].each do |date, count|
      annotations["outlier_#{date}"] = {
        type: "line",
        xMin: date.to_s,
        xMax: date.to_s,
        borderColor: "rgba(245, 158, 11, 0.3)",
        borderWidth: 1,
        borderDash: [ 4, 4 ],
        label: {
          display: true,
          content: "#{count} outlier#{count > 1 ? "s" : ""}",
          position: "start",
          backgroundColor: "rgba(245, 158, 11, 0.8)",
          color: "#fff",
          font: { size: 10 }
        }
      }
    end
    annotations
  end
end
