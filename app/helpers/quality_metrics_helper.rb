# frozen_string_literal: true

module QualityMetricsHelper
  def format_quality_score(score)
    return "--" if score.nil?

    format("%.1f%%", score * 100)
  end

  # Dark-mode colors for these text classes are handled by the global
  # unlayered overrides in application.tailwind.css (e.g. `.dark .text-green-600`),
  # which have higher cascade priority than Tailwind dark: utilities.
  def quality_score_color(score)
    return "text-gray-400" if score.nil?

    if score >= 0.8
      "text-green-600"
    elsif score >= 0.5
      "text-yellow-600"
    else
      "text-red-600"
    end
  end

  def quality_score_bar_color(score)
    return "bg-gray-300" if score.nil?

    if score >= 0.8
      "bg-green-500"
    elsif score >= 0.5
      "bg-yellow-500"
    else
      "bg-red-500"
    end
  end

  def improvement_delta_color(delta, invert: false)
    return "text-gray-400" if delta.nil?

    positive = invert ? delta.negative? : delta.positive?
    if positive
      "text-green-600"
    elsif invert ? delta.positive? : delta.negative?
      "text-red-600"
    else
      "text-gray-400"
    end
  end

  def improvement_delta_label(delta)
    return "--" if delta.nil?

    sign = delta.positive? ? "+" : ""
    "#{sign}#{number_to_percentage(delta * 100, precision: 1)}"
  end
end
