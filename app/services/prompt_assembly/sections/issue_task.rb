# frozen_string_literal: true

# Renders the issue implementation task template (title, body, and the
# step-by-step instructions). This is a required section — the assembler
# always includes it and never suppresses it.
class PromptAssembly::Sections::IssueTask
  include PromptAssembly::Sections::Base

  PROMPT_SLUG = "coding.issue_implementation"

  FALLBACK_PROMPT = <<~'PROMPT'.freeze
    # Task

    You are working on the following GitHub issue:

    **{{title}}** (#{{issue_number}})

    {{body}}

    # Instructions

    1. Install dependencies (`bundle install`, `yarn install`, etc.)
    {{setup_database_instruction}}
    2. Analyze the issue and understand what needs to be done
    3. Make the necessary code changes
    4. Run lint and fix any violations: `{{lint_command}}`
    5. Run the test suite and fix any failures: `{{test_command}}`
    6. Commit your changes with a descriptive message

    **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
    If the commit is rejected, read the error output carefully, fix the issues, and commit again.
    Keep iterating until the commit succeeds. Do not leave uncommitted changes.
  PROMPT

  private

  def build_section
    return selected_prompt_version.render(variables) if selected_prompt_version

    Prompts::Render.call(
      slug: PROMPT_SLUG,
      project: project,
      variables: variables,
      fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, variables) }
    )
  end

  def required
    true
  end

  def inclusion_reason
    "issue title, body, and implementation instructions"
  end

  def variables
    {
      title: issue.title.to_s,
      issue_number: issue.github_number.to_s,
      body: issue.body.to_s,
      lint_command: lint_command,
      test_command: test_command,
      setup_database_instruction: setup_database_instruction
    }
  end

  def selected_prompt_version
    version = agent_run&.prompt_version
    return unless version&.prompt&.slug == PROMPT_SLUG

    version
  end

  def lint_command
    Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.lint_commands_for(project))
  end

  def test_command
    Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.test_commands_for(project))
  end

  def setup_database_instruction
    Prompts::ServiceContainerSections.setup_database_instruction_for(project: project)
  end
end
