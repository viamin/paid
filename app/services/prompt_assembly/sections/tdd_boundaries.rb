# frozen_string_literal: true

# TDD phase boundaries that mirror Tdd::WriteGuard. This is a required section
# for TDD-governed runs, so the assembler always includes it and never
# suppresses it. The text describes the same file-change boundary the
# pre-commit hook enforces, expressed in agent-facing language.
#
# @spec PROMPT-ASSEMBLY-020 # @spec PROMPT-ASSEMBLY-023
class PromptAssembly::Sections::TddBoundaries
  include PromptAssembly::Sections::Base

  BOUNDARIES = {
    "test_writing" => <<~RULES.strip,
      # TDD Boundaries — test-writing run

      You are in the test-writing phase. The pre-commit hook enforces this:
      you may only change files under test paths (`spec/`, `test/`, `tests/`,
      `.ephemeral-tests/`) or the LID doc allowlist (`docs/`, `AGENTS.md`,
      `CLAUDE.md`, `.github/copilot-instructions.md`). Implementation files
      (anything outside those paths) will be rejected at commit time.

      Write the tests and any permitted LID documentation, commit them, and
      finish this run so Paid can publish the tests-only draft PR. Expected
      assertion failures that demonstrate missing behavior are permitted in
      this red phase; lint still passes, and you must resolve or report
      infrastructure, syntax, and unrelated failures. The red-phase hook
      reports test failures without requiring a hook bypass. These phase rules
      override generic instructions to make implementation changes or make all
      tests green.

      Committing tests does not unlock implementation within this run. Paid
      starts a separate implementation run only after `paid-tests-approved`:
      automated test review supplies that label in non-strict mode, while a
      human supplies it in strict mode.
    RULES
    "test_fixing" => <<~RULES.strip,
      # TDD Boundaries — test-fixing run

      You are in the test-fixing phase. You may change implementation code.
      You may only change test files if the PR has been returned to test
      review (`paid-tests-ready-for-review` label set on this run) — the
      pre-commit hook enforces this. To unlock test edits, swap the
      `paid-tests-approved` label for `paid-tests-ready-for-review` via the
      GitHub API proxy, return the PR to test review before editing tests, and
      then continue. Keep the approved tests green unless returning them to
      review is necessary; generic instructions never authorize test edits.
    RULES
    "refactor" => <<~RULES.strip,
      # TDD Boundaries — refactor run

      You are in the refactor phase. You may change implementation code only.
      Test files (`spec/`, `test/`, `tests/`, `.ephemeral-tests/`) are
      frozen — the pre-commit hook rejects any change to them. Do not edit
      tests to make them pass; make the implementation match them. Keep the
      approved test suite green while refactoring.
    RULES
    nil => ""
  }.freeze

  def self.applicable?(agent_run)
    agent_run.respond_to?(:tdd_governed?) && agent_run.tdd_governed?
  end

  private

  def build_section
    return "" unless agent_run&.tdd_governed?

    BOUNDARIES[agent_run.tdd_phase].to_s
  end

  def required
    true
  end

  def exclusion_reason
    "not_tdd_governed" unless agent_run&.tdd_governed?
  end

  def inclusion_reason
    "TDD phase guidance and write-boundary contract"
  end
end
