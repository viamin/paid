# frozen_string_literal: true

# Renders the issue implementation task template (title, body, and the
# step-by-step instructions). This is a required section — the assembler
# always includes it and never suppresses it.
class PromptAssembly::Sections::IssueTask
  include PromptAssembly::Sections::Base

  PROMPT_SLUG = "coding.issue_implementation"

  # The instruction block rendered into the issue-implementation prompt when
  # the project has quiet mode enabled. Kept identical to the PR follow-up
  # variant so the agent's commit-message contract is stable across run
  # shapes (#4232).
  QUIET_MODE_COMMIT_MESSAGE_BODY = <<~SECTION.freeze
    # Commit Message Is The Commentary Channel

    Quiet mode is enabled for this project: Paid does NOT post a summary
    comment after this push. The commit message is the only record of what
    this run changed and why. Every commit on this branch MUST therefore
    carry the reviewer-facing explanation in its message body.

    Subject line: conventional-commit style, ≤ 72 characters — for example
    `Implement: extract runner selection into AgentRun#select_runner` rather
    than `implement runner selection`.

    Commit body (one or more wrapped paragraphs):
    - What changed (the substantive code shape, not a list of file names).
    - Why it changed (which issue requirement, review comment, CI failure, or
      follow-up request it satisfies).
    - Anything the reviewer should know that the diff alone does not show.
  SECTION

  FALLBACK_PROMPT = <<~'PROMPT'.freeze
    # Task

    You are working on the following GitHub issue:

    **{{title}}** (#{{issue_number}})

    {{body}}

    # Criterion-Level Verification

    Human or external criteria require their actual inspectable evidence; an automated test cannot settle them.

    If this is an epic umbrella final audit, verify shipped behavior, tests,
    and documentation against its approved RDR/HLD/LLD/EARS and acceptance
    criteria. Do not treat closed child issues as sufficient evidence. Make
    bounded corrections where needed; otherwise record an evidence-backed,
    GitHub-visible outcome and close only when no required gaps remain.

    # Instructions

    1. Install dependencies (`bundle install`, `yarn install`, etc.)
    {{setup_database_instruction}}
    2. Analyze the issue and understand what needs to be done
    3. Before implementation, map every acceptance criterion to the smallest credible verification and record the plan in the PR/run evidence. Use a permanent system test for an important recurring user flow (for example provider API-key onboarding through welcome chat); use a focused unit/service test for a recurring rule or defect; use a PR-only ephemeral `.ephemeral-tests/` system/integration test for a complex one-off or non-essential flow, then remove it before merge; and use actual inspectable human or external evidence for human/external criteria. A broad green suite is not criterion coverage. Do not infer a pass from a test name, agent prose, or a skipped job. Write tests early enough to expose the failure.
    4. Make the necessary code changes
    5. Run lint and fix any violations: `{{lint_command}}`
    6. Run the test suite and fix any failures: `{{test_command}}`
    7. Commit your changes with a descriptive message

    If you open a pull request that requires human judgment before it can land,
    apply the structured review hold through the GitHub API proxy; no `gh` CLI
    exists in this environment. Use the repository and pull request number from
    the PR URL:

    ```bash
    curl -X POST --connect-timeout 10 --max-time 30 \
      "$GITHUB_API_URL/repos/<owner>/<repo>/issues/<pr_number>/labels" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN" \
      --data-binary '{"labels":["paid-hold-review"]}'
    ```

    Do not rely on prose in the pull request body: Paid auto-merge honors the
    label and surfaces the pull request in the Inbox until a human removes it.

    **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
    If the commit is rejected, read the error output carefully, fix the issues, and commit again.
    Keep iterating until the commit succeeds. Do not leave uncommitted changes.
  PROMPT

  private

  def build_section
    [ task_template, commit_message_guidance ].compact_blank.join("\n\n")
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
      setup_database_instruction: setup_database_instruction,
      commit_message_guidance: ""
    }
  end

  # Quiet mode (`Project#quiet_mode`) silently routes agent commentary into
  # commit messages instead of issue/PR comments. For issue-implementation
  # runs the agent still writes a descriptive message either way; in quiet
  # mode the body must explicitly cover the substantive change so the Git
  # log stays the project's authoritative review-tracking surface (#4232).
  # @spec QUIET-MODE-008
  def commit_message_guidance
    return "" unless quiet_mode?

    QUIET_MODE_COMMIT_MESSAGE_BODY
  end

  def quiet_mode?
    return false unless project

    project.respond_to?(:quiet_mode?) && project.quiet_mode?
  end

  def selected_prompt_version
    version = agent_run&.prompt_version
    return unless version&.prompt&.slug == PROMPT_SLUG

    version
  end

  def render_task_template
    return selected_prompt_version.render(variables) if selected_prompt_version

    Prompts::Render.call(
      slug: PROMPT_SLUG,
      project: project,
      variables: variables,
      fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, variables) }
    )
  end

  def task_template
    template = PromptAssembly::Sections::SafetyRules.strip_legacy_suffix(render_task_template)
    return template if template.include?("# Criterion-Level Verification")

    [ template, criterion_verification_guidance ].join("\n\n")
  end

  # Kept outside the persisted template so existing prompt versions gain the
  # contract immediately; the seed keeps it durable for new prompt records.
  # @spec PROMPT-ASSEMBLY-024
  def criterion_verification_guidance
    <<~GUIDANCE
      # Criterion-Level Verification

      Before implementation, map every acceptance criterion to the smallest
      credible verification and record the plan in the PR/run evidence. Use a
      permanent system test for an important recurring user flow (for example
      provider API-key onboarding through welcome chat); use a focused
      unit/service test for a recurring rule or defect; use a PR-only ephemeral
      `.ephemeral-tests/` system/integration test for a complex one-off or
      non-essential flow, then remove it before merge. Human or external
      criteria require their actual inspectable evidence; an automated test
      cannot settle them. A broad green suite is not criterion coverage. Do not
      infer a pass from a test name, agent prose, or a skipped job. Write tests
      early enough to expose the failure.
    GUIDANCE
  end

  # Whether the agent's runtime environment has a usable database service
  # container. The prompt and the pre-commit hook must agree on this to
  # avoid telling the agent contradictory things about whether
  # database-dependent verification can run (POLYGLOT-TEST-011).
  def database_available?
    return @database_available if defined?(@database_available)

    @database_available = Prompts::ServiceContainerSections.has_database_container?(
      project: project,
      agent_run: agent_run
    )
  end

  def lint_command
    Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.lint_commands_for(project, db_available: database_available?))
  end

  def test_command
    Prompts::LanguageCommands.format_for_prompt(
      Prompts::LanguageCommands.test_commands_for(project, db_available: database_available?)
    )
  end

  def setup_database_instruction
    Prompts::ServiceContainerSections.setup_database_instruction_for(
      project: project,
      agent_run: agent_run
    )
  end
end
