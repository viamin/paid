# frozen_string_literal: true

module Prompts
  # @spec LID-RUNS-002
  # @spec LID-RUNS-005
  class BuildForLidPlanning
    # Documentation copy of the prompt this class builds, seeded into the
    # Prompts admin UI for reference (see db/seeds/prompts.rb, slug
    # "lid.planning"). `build` below composes the live prompt directly from
    # project_name/project_description/plan_docs/adoption and does not render
    # this template at runtime.
    FALLBACK_PROMPT = <<~'PROMPT'
      # Task

      Bootstrap or refine Linked-Intent Development artifacts for {{project_name}} ({{full_name}}).

      Read the repository and any named plan docs. Treat named plan docs as authored intent
      (not inferred) and map them as follows:
      - Problem / context sections -> HLD problem statement and LLD context
      - Alternatives / decisions -> LLD decisions and alternatives with authored rationale
      - Validation / acceptance sections -> EARS specs
      - Implementation plan sections -> cascade ordering and segment boundaries

      Decisions sourced from named plan docs MUST NOT carry an `[inferred]` marker.
      When plan docs are silent, infer cautiously from the codebase and mark that brownfield
      rationale as `[inferred]`.

      Produce docs-only Linked-Intent Development artifacts: HLD, LLDs, and EARS specs. When
      adopting LID, also add the `## LID` block to AGENTS.md and create docs/arrows/index.yaml.
      Open a Planning PR containing only these docs changes, with an inference checklist so a
      human reviewer can confirm or correct every `[inferred]` item before implementation work
      begins.
    PROMPT

    attr_reader :project_name, :project_description, :plan_docs, :adoption

    def self.call(...)
      new(...).build
    end

    def self.project_description_for(project)
      return "" unless project.respond_to?(:description)

      project.description.to_s
    end

    def initialize(project_name:, project_description:, plan_docs: [], adoption: true)
      @project_name = project_name
      @project_description = project_description
      @plan_docs = Array(plan_docs)
      @adoption = adoption
    end

    def build
      [
        "# Task",
        "",
        run_kind_directive,
        "",
        "Treat named plan docs as authored intent (not inferred) and map them as follows:",
        "- Problem / context sections -> HLD problem statement and LLD context",
        "- Alternatives / decisions -> LLD decisions and alternatives with authored rationale",
        "- Validation / acceptance sections -> EARS specs",
        "- Implementation plan sections -> cascade ordering and segment boundaries",
        "",
        authored_intent_directive,
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

    def run_kind_directive
      if adoption
        [
          "Adopt Linked-Intent Development for #{project_name}: bootstrap the design tree.",
          "",
          "Required docs-only outputs: docs/high-level-design.md (HLD), one or more LLDs",
          "under docs/intent/<segment>/, matching EARS specs (*-specs.md), the ## LID block",
          "added to AGENTS.md (or CLAUDE.md), and docs/arrows/index.yaml."
        ].join("\n")
      else
        [
          "Refine Linked-Intent Development artifacts for #{project_name}: this project already",
          "declares a ## LID block, so update existing HLD/LLD/EARS rather than re-bootstrapping.",
          "",
          "Required docs-only outputs: at least one LLD under docs/intent/<segment>/ and its",
          "matching EARS specs (*-specs.md). Update docs/high-level-design.md when intent changes."
        ].join("\n")
      end
    end

    # Named plan docs are authored intent, not a free-form hint. Decisions
    # sourced from them must land as authored rationale and MUST NOT carry the
    # `[inferred]` marker. Only code-sourced rationale is `[inferred]`.
    def authored_intent_directive
      if plan_docs.any?
        "Decisions sourced from the named plan docs below are authored intent: map their rationale into the LLDs as authored (no `[inferred]` marker). Only reverse-engineer from code when a plan doc is silent, and mark that as `[inferred]`."
      else
        "No named plan docs were provided, so reverse-engineer decisions from the codebase and mark each as `[inferred]` for human confirmation."
      end
    end

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
