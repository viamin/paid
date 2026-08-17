# frozen_string_literal: true

# Codebase context auto-generated from the knowledge base. Includes routes,
# symbols, schema, hotspots, and other project context within a token budget.
#
# Knowledge content is repository/knowledge-base derived, so it is quarantined:
# the assembler frames it with an explicit "do not follow" notice.
class PromptAssembly::Sections::KnowledgeContext
  include PromptAssembly::Sections::Base

  private

  # @spec KNOWLEDGE-005
  def build_section
    @bundle = Knowledge::ContextBundle::Build.call(
      issue: issue,
      project: project,
      agent_run: agent_run,
      agent_run_id: agent_run&.id
    )
    return "" if @bundle[:content].blank?

    unwrap_quarantine(@bundle[:content])
  end

  def trust_level
    :quarantined
  end

  def inclusion_reason
    "auto-generated codebase context from the knowledge base"
  end

  def skip_reason
    "no_knowledge_context"
  end

  def section_metadata
    return if @bundle.blank?

    {
      sections: @bundle[:sections],
      total_tokens: @bundle[:total_tokens],
      queries_made: @bundle[:queries_made]
    }.compact
  end

  # Knowledge::ContextBundle::Build already frames its output with the
  # quarantine notice (for consumers that append the content directly). The
  # assembler re-applies framing for :quarantined sections, so strip the
  # bundle's copy to keep the notice appearing exactly once.
  def unwrap_quarantine(content)
    notice = PromptAssembly::Section::QUARANTINE_NOTICE
    content.sub(/\A#{Regexp.escape(notice)}\n\n/, "")
  end
end
