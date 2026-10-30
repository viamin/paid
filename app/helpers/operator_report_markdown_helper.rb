# frozen_string_literal: true

module OperatorReportMarkdownHelper
  INTERNAL_REPORT_TITLES = {
    "# RDR-067 Solo-Maintainer Shadow Evaluation Report" => "# Conformance Review Evaluation Report",
    "# RDR-070 Facet-Confidence Closeout Evaluation Report" => "# Facet-Confidence Closeout Evaluation Report"
  }.freeze

  # @spec INTENT-CONFORMANCE-ROLLOUT-009 @spec FACET-CONFIDENCE-020
  def operator_report_markdown(markdown)
    INTERNAL_REPORT_TITLES.reduce(markdown) do |rendered_markdown, (internal_title, operator_title)|
      rendered_markdown.sub(internal_title, operator_title)
    end
  end
end
