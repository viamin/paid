# frozen_string_literal: true

# The non-negotiable safety rules that every create_pr prompt must carry.
# This is a required section so the assembler always includes it and never
# suppresses it — even if the DB-stored template is modified to drop them.
#
# @spec PROMPT-ASSEMBLY-015
# @spec POLYGLOT-TEST-011
class PromptAssembly::Sections::SafetyRules
  include PromptAssembly::Sections::Base

  SAFETY_RULES = <<~RULES.strip
    # Rules — you MUST follow these

    - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
    - **Never use `--no-verify`** or any flag that skips git hooks.
    - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
    - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
    - Work within the existing codebase style and conventions
    - Do not modify unrelated files
    - Focus on completing the specific task in the issue

    When you're done, commit all your changes. Do not push.
  RULES

  TEST_WRITING_SAFETY_RULES = <<~RULES.strip
    # Rules — you MUST follow these

    - **Lint MUST pass before every commit.** Do not bypass hooks or disable linters.
    - In this test-writing run, expected assertion failures that demonstrate missing behavior are permitted. Resolve or clearly report infrastructure, syntax, and unrelated failures; do not treat them as red-phase evidence.
    - **Never use `--no-verify`** or any flag that skips git hooks.
    - **Fix forward** — if a check fails, fix the underlying issue or report the blocker. Do not bypass the check.
    - Work within the existing codebase style and conventions
    - Do not modify unrelated files
    - Focus on completing the specific task in the issue

    When you're done, commit the permitted tests and LID docs only. Do not push.
  RULES

  # Variant emitted when no database service container is provisioned for
  # this run. The container quality hooks will skip the database-dependent
  # test (and mutation) commands, so the standard "tests MUST pass" rule
  # would demand an unavailable suite pass. This variant keeps the lint
  # requirement, requires the runnable subset of tests to actually pass,
  # and explicitly requires the agent to report the skipped
  # database-dependent verification rather than silently passing or
  # provisioning the missing services itself (#4305, POLYGLOT-TEST-011).
  NO_DATABASE_SAFETY_RULES = <<~RULES.strip
    # Rules — you MUST follow these

    - **Lint MUST pass before every commit.** Do not bypass hooks or disable linters.
    - **Runnable tests MUST pass before every commit.** Run only the test suites you can actually execute in this environment, and fix every real failure in those. Do NOT mark skipped or infrastructure-blocked suites as passing.
    - **Report skipped database-dependent tests.** If the project's test command or pre-commit hook skips a database-dependent suite because no database is available in this environment, list that suite in your final answer and explain that verification was skipped, not passed.
    - **Do NOT provision or install missing services.** Do NOT attempt to install PostgreSQL, Redis, or any other infrastructure service to make an unavailable test suite run.
    - **Never use `--no-verify`** or any flag that skips git hooks.
    - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) or skip flags in test commands to silence failures. Fix the code instead.
    - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
    - Work within the existing codebase style and conventions
    - Do not modify unrelated files
    - Focus on completing the specific task in the issue

    When you're done, commit all your changes. Do not push.
  RULES

  LEGACY_RULES_SUFFIX = /
    \n{2,}
    (?:When\ you're\ done,\ commit\ all\ your\ changes\.\ Do\ not\ push\.\n{2,})?
    \#\ Rules\ —\ you\ MUST\ follow\ these
    \n{2,}
    (?:- .*(?:\n|$))+
    \s*
    \z
  /x.freeze

  def self.strip_legacy_suffix(text)
    text.to_s.sub(LEGACY_RULES_SUFFIX, "").rstrip
  end

  private

  def build_section
    # The TDD test-writing phase has its own rules ("expected assertion
    # failures are permitted") that the no-database variant doesn't
    # capture; check it first so a no-database test-writing run still gets
    # the test-writing semantics. The no-database variant applies to
    # ordinary create_pr runs where the agent is expected to land code
    # and verify it.
    return TEST_WRITING_SAFETY_RULES if agent_run&.tdd_test_writing_phase?
    return NO_DATABASE_SAFETY_RULES if database_unavailable?

    SAFETY_RULES
  end

  def required
    true
  end

  def inclusion_reason
    if database_unavailable?
      "non-negotiable safety rules (no-database variant — runner has no database service available)"
    else
      "non-negotiable safety rules"
    end
  end

  # Whether the agent's runtime environment has a usable database service
  # container. When no database is available, the safety rules must NOT
  # demand a database-dependent suite pass — the pre-commit hook already
  # no-op'd that command and the prompt's instruction step would otherwise
  # tell the agent contradictory things (#4305, POLYGLOT-TEST-011).
  def database_unavailable?
    !Prompts::ServiceContainerSections.has_database_container?(
      project: project,
      agent_run: agent_run
    )
  end
end
