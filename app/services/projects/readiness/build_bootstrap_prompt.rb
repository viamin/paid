# frozen_string_literal: true

module Projects
  module Readiness
    # Produces the bounded remediation instruction from persisted, structural
    # evidence; it never decides which files are missing.
    # @spec PROJECT-READINESS-007
    class BuildBootstrapPrompt
      def self.call(...)
        new(...).call
      end

      def initialize(project:)
        @project = project
      end

      def call
        <<~PROMPT
          Establish the missing test-harness prerequisites for #{project.full_name}.

          Inspect the actual checkout and make the smallest runnable setup change.
          You may change only CI configuration, project/scaffold manifests, test-directory layout, and tool configuration. Do not write application or business logic.

          Current readiness evidence:
          #{gaps}

          Configure real test execution appropriate to this checkout. Do not deliberately break CI: the later test-writing run owns the intentionally failing red phase.
        PROMPT
      end

      private

      attr_reader :project

      def gaps
        project.readiness_gaps.map { |gap| "- #{gap['description'] || gap[:description]}" }.join("\n")
      end
    end
  end
end
