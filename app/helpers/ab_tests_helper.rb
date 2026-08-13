# frozen_string_literal: true

module AbTestsHelper
  def ab_test_status_badge(status)
    classes = case status
    when "draft"
      "bg-gray-100 text-gray-700"
    when "running"
      "bg-blue-100 text-blue-700"
    when "completed"
      "bg-green-100 text-green-700"
    when "cancelled"
      "bg-red-100 text-red-700"
    else
      "bg-gray-100 text-gray-600"
    end

    tag.span(status.titleize, class: "inline-flex items-center rounded-md px-2 py-1 text-xs font-medium #{classes}")
  end

  def analysis_status_bg(status)
    case status
    when :winner_found then "bg-green-50"
    when :control_wins then "bg-yellow-50"
    when :no_significant_difference then "bg-gray-50"
    else "bg-blue-50"
    end
  end

  def analysis_status_text(status)
    case status
    when :winner_found then "text-green-800"
    when :control_wins then "text-yellow-800"
    when :no_significant_difference then "text-gray-800"
    else "text-blue-800"
    end
  end

  def analysis_status_label(status)
    case status
    when :winner_found then "Winner found!"
    when :control_wins then "Control is performing better than all variants."
    when :no_significant_difference then "No statistically significant difference detected."
    when :insufficient_data then "Insufficient data for analysis."
    else status.to_s.titleize
    end
  end

  def variant_row_class(variant, ab_test)
    if ab_test.winner_variant_id == variant.id
      "bg-green-50"
    elsif variant.is_control?
      "bg-gray-50"
    else
      ""
    end
  end
end
