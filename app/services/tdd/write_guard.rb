# frozen_string_literal: true

module Tdd
  # Enforces the run-scoped write boundaries from RDR-056's TDD mode:
  #
  # | Phase        | Allowed changes             | Forbidden changes           |
  # |--------------|------------------------------|------------------------------|
  # | test_writing | tests, applicable LID docs   | implementation code         |
  # | test_fixing  | implementation code          | tests, unless the run has   |
  # |              |                               | returned the PR to review   |
  # | refactor     | implementation code          | tests (no exception)        |
  #
  # A run with a blank `tdd_phase` is not TDD-governed and is always valid —
  # this preserves existing behavior for projects with tdd_mode "off" and for
  # goals that fall outside the TDD workflow entirely.
  #
  # @example
  #   result = Tdd::WriteGuard.call(agent_run: agent_run, changed_files: paths)
  #   result.valid?          # => false
  #   result.forbidden_files # => ["app/models/widget.rb"]
  #   result.reason          # => "test-writing runs may not change implementation code"
  class WriteGuard
    # Mirrors CreatePullRequestActivity#changed_test_files's test-path
    # convention so the guard and the rest of the pipeline agree on what
    # counts as a test file.
    TEST_PATH_PREFIXES = %w[spec/ test/ .ephemeral-tests/].freeze

    # Docs a test_writing run may touch alongside tests: LID artifacts and
    # the instruction files that carry the "## LID" block. Mirrors
    # CreatePullRequestActivity::LID_PLANNING_ALLOWED_PATTERNS.
    LID_DOC_PREFIXES = %w[docs/].freeze
    LID_DOC_EXACT_PATHS = %w[
      AGENTS.md
      CLAUDE.md
      .github/copilot-instructions.md
    ].freeze

    REASONS = {
      "test_writing" => "test-writing runs may not change implementation code",
      "test_fixing" => "test-fixing runs may not change tests without returning the PR to test review",
      "refactor" => "refactor runs may not change tests"
    }.freeze

    Result = Data.define(:valid?, :phase, :forbidden_files, :reason)

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, changed_files:)
      @agent_run = agent_run
      @changed_files = Array(changed_files)
    end

    def call
      Result.new(
        valid?: forbidden_files.empty?,
        phase: agent_run.tdd_phase,
        forbidden_files: forbidden_files.freeze,
        reason: REASONS[agent_run.tdd_phase]
      )
    end

    private

    attr_reader :agent_run, :changed_files

    def forbidden_files
      @forbidden_files ||= case agent_run.tdd_phase
      when "test_writing" then implementation_files
      when "test_fixing" then agent_run.tdd_returned_to_test_review? ? [] : test_files
      when "refactor" then test_files
      else []
      end
    end

    def test_files
      changed_files.select { |path| test_file?(path) }
    end

    def implementation_files
      changed_files.reject { |path| test_file?(path) || lid_doc?(path) }
    end

    def test_file?(path)
      TEST_PATH_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    end

    def lid_doc?(path)
      LID_DOC_PREFIXES.any? { |prefix| path.start_with?(prefix) } ||
        LID_DOC_EXACT_PATHS.include?(path)
    end
  end
end
