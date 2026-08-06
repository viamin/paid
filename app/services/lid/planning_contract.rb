# frozen_string_literal: true

module Lid
  # Validates the output contract of a completed `lid_planning` run.
  #
  # The docs-only allowlist (`CreatePullRequestActivity#validate_lid_planning_changed_files!`)
  # rejects forbidden paths; this service checks the *positive* contract: that the
  # required LID artifact set was actually produced. Adoption runs (the project has
  # no `lid_mode` yet) must bootstrap the full tree; refinement runs (the project
  # already declares `lid_mode`) must touch at least one segment's LLD and EARS
  # specs.
  #
  # The contract is run-kind aware so conversion/refinement is not held to the
  # stricter adoption requirements (a fresh `## LID` block and arrow index).
  #
  # @example
  #   result = Lid::PlanningContract.call(agent_run: run, changed_files: paths)
  #   result.valid?        # => true
  #   result.kind          # => "adoption"
  #   result.missing       # => []
  class PlanningContract
    HLD_PATH = "docs/high-level-design.md"
    ARROWS_PATH = "docs/arrows/index.yaml"
    INSTRUCTION_FILES = %w[AGENTS.md CLAUDE.md .github/copilot-instructions.md].freeze
    INTENT_PATTERN = %r{\Adocs/intent/}
    SPECS_PATTERN = %r{\Adocs/intent/.+-specs\.md\z}

    # @spec LID-RUNS-007
    Result = Data.define(:kind, :valid?, :missing, :plan_doc_weighted) do
      def adoption?
        kind == "adoption"
      end

      def refinement?
        kind == "refinement"
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, changed_files:)
      @agent_run = agent_run
      @changed_files = Array(changed_files)
    end

    def call
      Result.new(
        kind: kind,
        valid?: missing.empty?,
        missing: missing.freeze,
        plan_doc_weighted: agent_run.plan_docs_present?
      )
    end

    private

    attr_reader :agent_run, :changed_files

    def kind
      agent_run.project.lid_mode.present? ? "refinement" : "adoption"
    end

    def adoption?
      kind == "adoption"
    end

    def missing
      gaps = []
      gaps << "high-level design (#{HLD_PATH})" if adoption? && !touched?(HLD_PATH)
      gaps << "at least one LLD under docs/intent/" unless any_intent_doc?
      gaps << "at least one EARS spec (*-specs.md under docs/intent/)" unless any_specs_doc?
      if adoption?
        gaps << "instruction file with ## LID block (#{INSTRUCTION_FILES.join(" or ")})" unless touched_instruction_file?
        gaps << "LID arrow index (#{ARROWS_PATH})" unless touched?(ARROWS_PATH)
      end
      gaps
    end

    def touched?(path)
      changed_files.include?(path)
    end

    def any_intent_doc?
      changed_files.any? { |path| path.match?(INTENT_PATTERN) }
    end

    def any_specs_doc?
      changed_files.any? { |path| path.match?(SPECS_PATTERN) }
    end

    def touched_instruction_file?
      changed_files.intersect?(INSTRUCTION_FILES)
    end
  end
end
