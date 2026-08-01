# frozen_string_literal: true

module Prompts
  class BuildForLidPlanning
    # Documentation copy of the prompt this class builds, seeded into the
    # Prompts admin UI for reference (see db/seeds/prompts.rb, slug
    # "lid.planning"). `build` below composes the live prompt directly from
    # project_name/project_description/plan_docs and does not render this
    # template at runtime.
    FALLBACK_PROMPT = <<~'PROMPT'
      # Task

      Bootstrap or refine Linked-Intent Development artifacts for {{project_name}} ({{full_name}}).

      Read the repository and any named plan docs. Prioritize named plan docs over code
      inference when they are available. Treat them as authored intent and map them as follows:
      - Problem / context sections -> HLD problem statement and LLD context
      - Alternatives / decisions -> LLD decisions and alternatives with authored rationale
      - Validation / acceptance sections -> EARS specs
      - Implementation plan sections -> cascade ordering and segment boundaries

      When plan docs are silent, infer cautiously from the codebase and mark brownfield
      rationale as `[inferred]`.

      Produce docs-only Linked-Intent Development artifacts: HLD, LLDs, and EARS specs. Add
      the `## LID` block to AGENTS.md and create docs/arrows/index.yaml. Open a Planning PR
      containing only these docs changes, with an inference checklist so a human reviewer can
      confirm or correct every `[inferred]` item before implementation work begins.
    PROMPT

    attr_reader :project_name, :project_description, :plan_docs

    def self.call(...)
      new(...).build
    end

    def self.project_description_for(project)
      return "" unless project.respond_to?(:description)

      project.description.to_s
    end

    def initialize(project_name:, project_description:, plan_docs: [])
      @project_name = project_name
      @project_description = project_description
      @plan_docs = Array(plan_docs)
    end

    def build
      [
        "# Task",
        "",
        "Bootstrap or refine Linked-Intent Development artifacts for #{project_name}.",
        "",
        "Prioritize named plan docs over code inference when they are available.",
        "Treat them as authored intent and map them as follows:",
        "- Problem / context sections -> HLD problem statement and LLD context",
        "- Alternatives / decisions -> LLD decisions and alternatives with authored rationale",
        "- Validation / acceptance sections -> EARS specs",
        "- Implementation plan sections -> cascade ordering and segment boundaries",
        "",
        "Project description:",
        project_description.to_s.strip,
        "",
        plan_docs_section,
        "",
        "When plan docs are silent, infer cautiously from the codebase and mark brownfield rationale as `[inferred]`."
      ].join("\n").strip
    end

    private

    def plan_docs_section
      return "Named plan docs: none provided." if plan_docs.empty?

      lines = [ "Named plan docs:" ]
      plan_docs.each do |doc|
        lines << "- #{plan_doc_name(doc)}"
      end
      lines.join("\n")
    end

    def plan_doc_name(doc)
      doc.fetch(:name) { doc.fetch("name") }
    end
  end
end
