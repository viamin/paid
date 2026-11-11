# frozen_string_literal: true

# Renders the issue implementation task template (title, body, and the
# step-by-step instructions). This is a required section — the assembler
# always includes it and never suppresses it.
class PromptAssembly::Sections::IssueTask
  include PromptAssembly::Sections::Base

  PROMPT_SLUG = "coding.issue_implementation"
  CRITERION_VERIFICATION_REQUIREMENTS = [
    /Before implementation, map every acceptance criterion to the smallest\s+credible verification/,
    /permanent system test for an important recurring user flow/,
    /focused\s+unit\/service test for a recurring rule or defect/,
    /PR-only ephemeral\s+`\.ephemeral-tests\/` system\/integration test for a complex one-off or\s+non-essential flow/,
    /Human or external criteria require their actual inspectable evidence/,
    /A broad green suite is not criterion coverage\./,
    /Do not infer a pass from a test name, agent prose, or a skipped job\./
  ].freeze

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

  # Review-hold decision criteria for issue-implementation runs (#4974).
  # Shared byte-for-byte by the in-code fallback template and the seeded
  # `coding.issue_implementation` prompt so the two cannot drift, and
  # appended to project prompt overrides that still carry the pre-#4974
  # wording. `{{merge_delegation_note}}` is filled from the project's
  # effective merge posture at render time.
  # @spec AUTO-MERGE-009 @spec PROMPT-ASSEMBLY-026
  REVIEW_HOLD_GUIDANCE_BLOCK = <<~'BLOCK'.freeze
    # Review Holds

    {{merge_delegation_note}}

    Apply the `paid-hold-review` label only when your assigned work leaves a
    specific unresolved decision that automation is not authorized to make —
    for example an explicit design or intent approval gate, a material change
    to the pull request's scope or authority, or a decision the issue, its
    approved design, or project policy explicitly reserves for a human. A
    request for review, screenshots, or confirmation is normal verification
    work, not such a decision.

    Do not apply the label merely because the change is user-facing, the pull
    request or a reviewer asks for screenshots, review, or confirmation, CI or
    an automated bot review is still running, or you feel generally cautious.
    Missing evidence follows the criterion-level verification and blocker path
    above — not a review hold.

    Hold only the pull request your run creates or materially changes. Do not
    add a hold to another existing pull request you merely encounter while
    completing a dependency or bookkeeping issue, unless your assigned task
    explicitly requires reviewing or holding that pull request.

    When a hold is warranted, record the concrete unresolved decision, why the
    normal delegated checks cannot settle it, and the PR/run/issue evidence in
    the pull request description or a PR comment so an operator can act on it.
    Do not rely on prose in the pull request body: Paid auto-merge honors the
    label and surfaces the pull request in the Inbox until a human removes it.
    Apply the label through the GitHub API proxy; no `gh` CLI exists in this
    environment. Use the repository and pull request number from the PR URL:

    ```bash
    curl -X POST --connect-timeout 10 --max-time 30 \
      "$GITHUB_API_URL/repos/<owner>/<repo>/issues/<pr_number>/labels" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN" \
      --data-binary '{"labels":["paid-hold-review"]}'
    ```
  BLOCK

  # Phrases every refined hold block carries. A rendered task template
  # missing any of them predates #4974 (typically a project prompt override
  # or a pinned run version) and gets the block appended.
  REVIEW_HOLD_REQUIREMENTS = [
    /# Review Holds/,
    /specific\s+unresolved\s+decision\s+that\s+automation\s+is\s+not\s+authorized\s+to\s+make/,
    /explicit\s+design\s+or\s+intent\s+approval\s+gate/,
    /user-facing/,
    /creates\s+or\s+materially\s+changes/,
    /record\s+the\s+concrete\s+unresolved\s+decision/
  ].freeze

  # Rendered into REVIEW_HOLD_GUIDANCE_BLOCK when the project's effective
  # merge policy already merges agent PRs without a human (#4922 guard).
  MERGE_DELEGATION_NOTE_DELEGATED = <<~NOTE.freeze
    This project's effective merge policy delegates auto-merge for agent pull
    requests like the one this run opens: once the normal automated checks
    pass, it merges without a human. Ordinary merge decisions are delegated —
    do not re-introduce human review with a hold.
  NOTE

  # Rendered when agent PRs are not on an automated merge path; holds stay
  # available for genuine human-only decisions (#4181) but never for
  # ordinary review or verification work.
  MERGE_DELEGATION_NOTE_NOT_DELEGATED = <<~NOTE.freeze
    This project's effective merge policy does not delegate auto-merge for
    agent pull requests; ordinary merges are not automated here. The hold
    label remains reserved for the specific human-only decisions below, never
    for ordinary review or verification work.
  NOTE

  # Rendered when the posture cannot be resolved from the project record.
  MERGE_DELEGATION_NOTE_UNKNOWN = <<~NOTE.freeze
    When the project's effective merge policy delegates auto-merge, ordinary
    merge decisions for this run's pull request are delegated to automation;
    the hold criteria below still apply only to specific human-only
    decisions.
  NOTE

  FALLBACK_PROMPT = (<<~'PROMPT' + REVIEW_HOLD_GUIDANCE_BLOCK + "\n" + <<~'PROMPT').freeze
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

    {{commit_message_guidance}}

  PROMPT
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
      commit_message_guidance: "",
      merge_delegation_note: merge_delegation_note
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

  # @spec PROMPT-ASSEMBLY-024
  def task_template
    template = PromptAssembly::Sections::SafetyRules.strip_legacy_suffix(render_task_template)
    template = with_criterion_verification_guidance(template)
    with_review_hold_guidance(template)
  end

  def criterion_verification_requirements_present?(template)
    CRITERION_VERIFICATION_REQUIREMENTS.all? { |requirement| template.match?(requirement) }
  end

  def with_criterion_verification_guidance(template)
    return template if criterion_verification_requirements_present?(template)

    [ template, criterion_verification_guidance(include_heading: !criterion_verification_heading?(template)) ].join("\n\n")
  end

  # Project prompt overrides and pinned run versions can predate #4974 and
  # still carry the vague "requires human judgment" wording (or no hold
  # guidance at all). Append the refined block — with the project's live
  # merge posture — so every run receives the narrowed decision rule
  # regardless of template source.
  # @spec AUTO-MERGE-009 @spec PROMPT-ASSEMBLY-026
  def with_review_hold_guidance(template)
    return template if review_hold_requirements_present?(template)

    [ template, review_hold_guidance ].join("\n\n")
  end

  def review_hold_requirements_present?(template)
    REVIEW_HOLD_REQUIREMENTS.all? { |requirement| template.match?(requirement) }
  end

  def review_hold_guidance
    Prompts::Render.interpolate(
      REVIEW_HOLD_GUIDANCE_BLOCK,
      { merge_delegation_note: merge_delegation_note }
    )
  end

  # Statement of whether the project's effective merge policy already
  # delegates ordinary merge decisions for agent PRs. When it does, the
  # agent must not convert normal review/verification work (#4922) into a
  # discretionary hold; when it does not, genuine human-only decisions
  # (#4181) still hold.
  # @spec AUTO-MERGE-009
  def merge_delegation_note
    return MERGE_DELEGATION_NOTE_UNKNOWN unless merge_posture_resolvable?

    if delegated_auto_merge?
      MERGE_DELEGATION_NOTE_DELEGATED
    else
      MERGE_DELEGATION_NOTE_NOT_DELEGATED
    end
  end

  def merge_posture_resolvable?
    project.respond_to?(:auto_merge_bot_authored?) && project.respond_to?(:auto_merge_mode)
  end

  def delegated_auto_merge?
    project.auto_merge_bot_authored? && project.auto_merge_mode.to_s == "all"
  end

  def criterion_verification_heading?(template)
    template.include?("# Criterion-Level Verification")
  end

  # Kept outside the persisted template so existing prompt versions gain the
  # contract immediately; the seed keeps it durable for new prompt records.
  def criterion_verification_guidance(include_heading:)
    <<~GUIDANCE
      #{"# Criterion-Level Verification\n" if include_heading}
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
