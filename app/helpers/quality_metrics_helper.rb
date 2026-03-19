# frozen_string_literal: true

module QualityMetricsHelper
  def format_quality_score(score)
    return "--" if score.nil?

    format("%.1f%%", score * 100)
  end

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
end
