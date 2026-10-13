# frozen_string_literal: true

# The non-negotiable safety rules that every create_pr prompt must carry.
# This is a required section so the assembler always includes it and never
# suppresses it — even if the DB-stored template is modified to drop them.
#
# @spec PROMPT-ASSEMBLY-015
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
    return TEST_WRITING_SAFETY_RULES if agent_run&.tdd_test_writing_phase?

    SAFETY_RULES
  end

  def required
    true
  end

  def inclusion_reason
    "non-negotiable safety rules"
  end
end
