# frozen_string_literal: true

module CostDashboardHelper
  def format_cost_cents(cents)
    "$#{format('%.2f', cents / 100.0)}"
  end

  def budget_status_color(usage_percent, alert_threshold_percent = 80)
    if usage_percent >= 100
      "red"
    elsif usage_percent >= alert_threshold_percent
      "yellow"
    else
      "green"
    end
  end

  def budget_status_classes(color)
    case color
    when "red"
      { bg: "bg-red-100", text: "text-red-700", bar: "bg-red-500", ring: "ring-red-200" }
    when "yellow"
      { bg: "bg-yellow-100", text: "text-yellow-700", bar: "bg-yellow-500", ring: "ring-yellow-200" }
    when "gray"
      { bg: "bg-gray-100", text: "text-gray-600", bar: "bg-gray-400", ring: "ring-gray-200" }
    else
      { bg: "bg-green-100", text: "text-green-700", bar: "bg-green-500", ring: "ring-green-200" }
    end
  end

  def budget_type_label(budget_type)
    case budget_type
    when "daily" then "Daily"
    when "monthly" then "Monthly"
    when "per_run" then "Per Run"
    else budget_type.titleize
    end
  end
end
