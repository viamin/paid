# frozen_string_literal: true

module Projects::ShadowEvaluationsHelper
  def review_requirement_title(document)
    heading = document[:content].to_s.lines.find { |line| line.match?(/\A\#{1,3}\s+/) }
    heading&.sub(/\A\#+\s*/, "")&.strip.presence || File.basename(document[:path], ".md").humanize
  end

  def review_decision_text(outcome)
    {
      "within_scope" => "Matches the approved requirements",
      "material_drift" => "Changes the approved requirements",
      "uncertain" => "Not enough information",
      "not_evaluated" => "AI review unavailable"
    }.fetch(outcome, "Not reviewed")
  end
end
