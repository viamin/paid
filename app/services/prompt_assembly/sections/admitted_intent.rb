# frozen_string_literal: true

# Immutable confidence-driven context captured at run admission. It never
# reads current facet rows, so later evidence remains visibly subsequent work.
# @spec FACET-CONFIDENCE-013 @spec CONFIDENCE-DELIVERY-007
class PromptAssembly::Sections::AdmittedIntent
  include PromptAssembly::Sections::Base

  private

  def build_section
    return "" if snapshot.blank?

    [ "# Admitted Intent Baseline", guidance, baseline_lines, facet_lines ].reject(&:blank?).join("\n\n")
  end

  def snapshot
    @snapshot ||= agent_run&.external_metadata&.fetch("admitted_intent", {}) || {}
  end

  def guidance
    "Implement this admitted baseline. Later evidence is follow-up work and does not change this run's scope."
  end

  def facet_lines
    Array(snapshot["facets"]).map { |facet| format_facet(facet) }.join("\n")
  end

  def baseline_lines
    lines = []
    lines << "Admitted design revision: #{snapshot["design_baseline"] || "unknown"}"
    paths = Array(snapshot["design_document_paths"])
    lines << "Admitted design documents: #{paths.join(", ")}" if paths.present?
    lines.join("\n")
  end

  def format_facet(facet)
    direction = " (#{facet["direction"]})" if facet["direction"].present?
    [
      "- #{facet["name"]}#{direction}: intent #{facet["intent_score"] || "unknown"}, technical #{facet["technical_score"] || "unknown"}",
      "  Expressed intent: #{Array(facet["expressed_intent"]).join("; ").presence || "none recorded"}",
      "  Inferred fit: #{facet["inferred_fit"].presence || "none recorded"}",
      "  Demonstrated feasibility: #{Array(facet["demonstrated_feasibility"]).join("; ").presence || "none recorded"}"
    ].join("\n")
  end

  def inclusion_reason
    "immutable confidence-driven admitted intent"
  end

  def skip_reason
    "no_admitted_intent_snapshot"
  end
end
