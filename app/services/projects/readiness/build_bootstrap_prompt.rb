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
          #{heading} for #{project.full_name}.

          Inspect the actual checkout and make the smallest runnable setup change.
          You may change only CI configuration, project/scaffold manifests, test-directory layout, and tool configuration. Do not write application or business logic.

          Current readiness evidence:
          #{gaps}

          #{setup_instructions}
        PROMPT
      end

      private

      attr_reader :project

      def gaps
        project.readiness_gaps.map { |gap| "- #{gap['description'] || gap[:description]}" }.join("\n")
      end

      def heading
        return "Establish the missing interactive-verification prerequisites" if verification_gaps? && !test_harness_gaps?
        return "Establish the missing test-harness prerequisites" if test_harness_gaps?

        "Establish the missing project-readiness prerequisites"
      end

      def setup_instructions
        [ verification_setup_instructions, test_harness_setup_instructions ].compact.join("\n\n")
      end

      def verification_setup_instructions
        return unless verification_gaps?

        "Repair the checkout's interactive-verification setup, including .paid/screenshots.yml, " \
          "an applicable application start command, and configuration for declared services. " \
          "Do not write tests or application logic."
      end

      def test_harness_setup_instructions
        return unless test_harness_gaps?

        "Configure real test execution appropriate to this checkout. Do not deliberately break CI: " \
          "the later test-writing run owns the intentionally failing red phase."
      end

      def verification_gaps?
        gap_kinds.intersect?(Rules::Verification::GAP_KINDS)
      end

      def test_harness_gaps?
        gap_kinds.intersect?(Rules::Tdd::GAP_KINDS)
      end

      def gap_kinds
        project.readiness_gaps.filter_map { |gap| gap["kind"] || gap[:kind] }
      end
    end
  end
end
