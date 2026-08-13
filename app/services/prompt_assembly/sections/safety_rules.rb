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

  private

  def build_section
    SAFETY_RULES
  end

  def required
    true
  end

  def inclusion_reason
    "non-negotiable safety rules"
  end
end
