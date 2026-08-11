# frozen_string_literal: true

module Features
  # Validates the output contract of a completed `create_feature` run.
  #
  # The docs-only allowlist (`CreatePullRequestActivity#validate_lid_planning_changed_files!`)
  # rejects forbidden paths; this service checks the *positive* contract: that the
  # required RDR artifact set was actually produced. A successful `create_feature`
  # run must produce a new RDR document under `docs/rdrs/` with every required
  # section (per the RDR template in `docs/rdrs/README.md`) and must update the
  # RDR index in `docs/rdrs/README.md` to reference the new entry.
  #
  # The contract complements `Lid::PlanningContract`: it gates the docs-only PR
  # on RDR structural completeness the same way the LID contract gates the
  # Planning PR on LID artifact completeness. Incomplete RDRs are caught before
  # they reach human review, mirroring the "contract before PR" pattern from
  # RDR-051.
  #
  # Callers pass file bodies explicitly via `contents` so the contract stays
  # source-agnostic — the activity that opens the PR reads the worktree, the
  # next caller might fetch them from a different source, but the contract is
  # concerned only with the structural check.
  #
  # @example
  #   result = Features::RdrContract.call(
  #     agent_run: run,
  #     changed_files: paths,
  #     contents: { "docs/rdrs/RDR-053-..." => rdr_body,
  #                 "docs/rdrs/README.md" => readme_body }
  #   )
  #   result.valid?        # => true
  #   result.new_rdr_path  # => "docs/rdrs/RDR-053-new-feature-creation.md"
  #   result.missing       # => []
  class RdrContract
    RDRS_DIR = "docs/rdrs"
    INDEX_PATH = "docs/rdrs/README.md"
    RDR_PATTERN = %r{\Adocs/rdrs/RDR-\d{3,}[a-z0-9\-]*\.md\z}

    # Required RDR sections, listed in the order they appear in the template
    # (`docs/rdrs/README.md` -> "Creating New RDRs"). Names use the literal
    # heading text so the contract matches what a human reviewer would look for.
    # Each name is wrapped in a string array literal so multi-word section
    # titles ("Problem Statement", "Trade-offs and Consequences") are not split
    # on whitespace the way `%w[]` would.
    REQUIRED_SECTIONS = [
      "Metadata",
      "Problem Statement",
      "Context",
      "Research Findings",
      "Proposed Solution",
      "Alternatives Considered",
      "Trade-offs and Consequences",
      "Implementation Plan",
      "Validation"
    ].freeze

    Result = Data.define(:new_rdr_path, :valid?, :missing, :index_updated) do
      alias_method :valid?, :valid?
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, changed_files:, contents: {})
      @agent_run = agent_run
      @changed_files = Array(changed_files)
      @contents = contents.to_h.transform_keys(&:to_s)
    end

    def call
      Result.new(
        new_rdr_path: new_rdr_path,
        valid?: missing.empty?,
        missing: missing.freeze,
        index_updated: index_updated?
      )
    end

    private

    attr_reader :agent_run, :changed_files, :contents

    def new_rdr_path
      new_rdr_paths.first
    end

    def new_rdr_paths
      changed_files.select { |path| path.match?(RDR_PATTERN) }
    end

    def missing
      gaps = []
      gaps << "new RDR under #{RDRS_DIR}/ (RDR-NNN-*.md)" if new_rdr_path.nil?
      gaps.concat(section_gaps) if new_rdr_path
      gaps << "RDR index update (#{INDEX_PATH})" unless index_updated?
      gaps
    end

    def section_gaps
      body = contents.fetch(new_rdr_path, "")
      REQUIRED_SECTIONS.reject { |section| body.include?("## #{section}") }
                       .map { |section| "RDR section: ## #{section}" }
    end

    def index_updated?
      return false unless new_rdr_path
      return false unless changed_files.include?(INDEX_PATH)

      index_body.include?(File.basename(new_rdr_path))
    end

    def index_body
      contents.fetch(INDEX_PATH, "")
    end
  end
end
