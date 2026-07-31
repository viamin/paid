# frozen_string_literal: true

module Prompts
  class BuildForLidPlanning
    attr_reader :project_name, :project_description, :plan_docs

    def self.call(...)
      new(...).build
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
        lines << "- #{doc.fetch(:name)}"
      end
      lines.join("\n")
    end
  end
end
