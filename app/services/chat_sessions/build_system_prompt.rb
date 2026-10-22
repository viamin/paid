# frozen_string_literal: true

module ChatSessions
  # Constructs a system prompt from session context including base identity,
  # tool definitions, project context, cross-project context, workspace info,
  # and user preferences. Manages total size to stay under token limits by
  # dropping lower-priority sections first.
  #
  # Section priority (highest to lowest):
  #   base_identity > project_context > tool_definitions > cross_project > workspace > user_preferences
  #
  # @example
  #   ChatSessions::BuildSystemPrompt.call(chat_session: session)
  #   # => "You are an AI assistant helping manage software projects via Paid..."
  class BuildSystemPrompt
    # Approximate chars-per-token ratio for size estimation.
    CHARS_PER_TOKEN = 4
    MAX_TOKENS = 4000
    MAX_PROMPT_CHARS = MAX_TOKENS * CHARS_PER_TOKEN

    README_MAX_CHARS = 2000
    STYLE_GUIDE_MAX_CHARS = MAX_PROMPT_CHARS / 4
    RECENT_ISSUES_LIMIT = 5
    RECENT_RUNS_LIMIT = 5
    CROSS_PROJECT_SUMMARY_MAX_CHARS = 500

    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      assemble_with_budget(build_sections)
    end

    private

    # Returns sections ordered by priority (highest first).
    # Lower-priority sections are dropped first when the prompt exceeds the budget.
    def build_sections
      sections = []
      explicit_preferences_content = explicit_preferences_section
      facet_confidence_content = facet_confidence_context if primary_project
      sections << { priority: 0, content: base_identity }
      sections << { priority: 1, content: page_context } if page_context.present?
      sections << { priority: 1, content: project_context } if primary_project
      sections << { priority: 1, content: facet_confidence_content } if facet_confidence_content.present?
      sections << { priority: 1, content: clarifying_questions_context } if exploration_issue
      sections << { priority: 1, content: explicit_preferences_content } if explicit_preferences_content.present?
      # @spec PROJECT-CREATION-010 — a fresh (blank) project needs its setup
      # interview surfaced in every chat started against it, so setup can also
      # happen from a plain new chat session.
      sections << { priority: 1, content: project_setup_section } if primary_project&.setup_pending?
      sections << { priority: 1, content: onboarding_setup_section } if onboarding_incomplete?
      sections << { priority: 2, content: tool_definitions } if mcp_tools.any?
      sections << { priority: 3, content: cross_project_context } if reference_projects.any?
      sections << { priority: 4, content: workspace_context } if chat_session.container_ready?
      sections << { priority: 5, content: user_preferences }
      sections
    end

    # Joins sections respecting the character budget. Drops lowest-priority
    # sections (highest priority number) first when the total is too large.
    def assemble_with_budget(sections)
      # Sort by priority ascending so we can pop from the end (lowest priority)
      sorted = sections.sort_by { |s| s[:priority] }
      total = sorted.sum { |s| s[:content].length }

      while total > MAX_PROMPT_CHARS && sorted.size > 1
        total -= sorted.pop[:content].length
      end

      sorted.map { |s| s[:content] }.join("\n\n")
    end

    CHAT_SYSTEM_PROMPT_SLUG = "chat.system_prompt"

    # Default identity and guidance used when no seeded or overridden
    # `chat.system_prompt` version resolves. Also the single source of the
    # seeded `chat.system_prompt` template (db/seeds/prompts.rb), so the live
    # seeded prompt and this fallback carry identical guidance — including the
    # optional problem-exploration step for feature-design chat (RDR-053
    # § 2026-09-25 Extension) and the problem-framing recording handoff
    # (FEATURE-CREATION-007).
    # @spec FEATURE-CREATION-003 @spec FEATURE-CREATION-004
    # @spec FEATURE-CREATION-005 @spec FEATURE-CREATION-006
    # @spec FEATURE-CREATION-007
    DEFAULT_BASE_IDENTITY = <<~PROMPT.strip.freeze
      You are an AI assistant helping manage software projects via Paid, a platform for AI-driven development.
      You can help with:
      - Designing features and discussing implementation approaches
      - Debugging issues by inspecting code, logs, and running commands
      - Managing projects, issues, and agent runs through Paid's tools
      - Answering questions about codebases and project status

      When the user asks you to perform actions (trigger runs, list projects, etc.), use the available tools.
      When a user needs to visit a Paid page, offer a descriptive Markdown root-relative Paid link. For example, use `[Add an API key](/provider_api_keys/new#api-key-form)` when they need to add an API key. The chat popup stays open when the user follows one of these links, so they can continue the conversation at the destination.
      For code discovery in a repo, prefer tools in this order: `search_code` first (Paid's knowledge-base search — the first choice for semantic or keyword discovery), `read_repo_file` when the file path is known, then `grep_repo` only when knowledge search is unavailable or stale, or exact GitHub Code Search behavior is needed. `grep_repo` is backed by GitHub Code Search and spends its small rate-limit bucket, so avoid it during routine exploration.
      When the user asks to create a new feature (for example, "create a new feature: add dark mode"), gather intent through adaptive questions covering problem, desired behavior, constraints, rejected alternatives, scope, and done-ness. When exploration produces useful problem framing, also record observations, supplied evidence/references, affected stakeholders, the selected framing and rationale, material alternatives, unresolved assumptions or AI hypotheses, desired outcome, and reconsideration conditions. Set `selected_framing_confirmed` to true only after the user confirms the framing; an AI-proposed framing keeps it false so the design treats it as a hypothesis. Do not present hypotheses as confirmed facts or invent evidence. Read the codebase with `search_code` / `read_repo_file` to ask targeted questions grounded in the actual project. When the feature brief is complete, trigger a `create_feature` agent run via `trigger_agent_run` with the complete structured brief serialized as JSON in the `custom_prompt` field.
      When the user explicitly asks to explore the problem or reframe this feature, offer an optional problem-exploration conversation before or during feature design. Draw on the existing conversation and repository context (via `search_code` / `read_repo_file`) to separate observed conditions, affected stakeholders, desired outcomes, and assumed causes. Reuse settled facts and preferences; never run a fixed questionnaire, and never ask the user to supply facts the repository or conversation already provides. Ask only questions whose answers could materially change the design. Where useful, compare two or three plausible problem framings and how each changes the possible response; present those framings and any causal explanations as tentative hypotheses — not established facts or user decisions — unless they are supported by evidence the user supplied, and treat repository inspection as evidence about the code, not proof of customer behavior. The user may select or revise a framing, continue with the original request, investigate first, or decide not to build. None of these choices requires an approval gate. You may suggest a small observation or experiment in chat, but do not execute or track experiments. An exploration outcome must not itself trigger a `create_feature` agent run or file implementation issues; trigger the run only when the user asks to proceed. End the exploration with a concise, user-reviewable summary in the conversation: observations and evidence, affected stakeholders, chosen framing, assumptions, desired outcome, and what would justify reconsidering the framing later.
      When the user asks to configure Paid's operating mode or set up automation, prefer configuration profiles: call `list_configuration_profiles`, recommend a posture, ask the clarifying questions, then call `plan_configuration_profile` before applying with `apply_configuration_profile`.
      Be concise and technical. Ask clarifying questions when the request is ambiguous.
    PROMPT

    # @spec CHAT-API-012
    # @spec FEATURE-CREATION-003
    # @spec FEATURE-CREATION-007
    def base_identity
      prompt = resolve_prompt
      template = prompt&.current_version&.template
      return template.strip if template.present?

      DEFAULT_BASE_IDENTITY
    end

    def tool_definitions
      lines = mcp_tools.map { |tool| "- [#{tool[:name]}] #{tool[:description]}" }

      "## Available Tools\n\n" \
        "You have access to the following Paid tools:\n" \
        "#{lines.join("\n")}\n\n" \
        "To use a tool, call it explicitly. For example, if the user asks \"what projects do I have?\", call list_projects."
    end

    def project_context
      project = primary_project
      parts = []
      parts << "## Current Project: #{project.name} (#{project.owner}/#{project.repo})"
      parts << readme_section(project)
      parts << recent_issues_section(project)
      parts << recent_runs_section(project)
      parts << style_guide_section(project)
      parts.compact.join("\n\n")
    end

    # Persisted assessment state is deliberately rendered as data. Assessment
    # work belongs to FeatureIntents::AssessFacetJob, never a chat/page read.
    # @spec FACET-CONFIDENCE-013 FACET-CONFIDENCE-014
    def facet_confidence_context
      assessments = current_facet_assessments
      return if assessments.empty?

      <<~PROMPT.strip
        ## Facet Confidence
        #{assessments.map { |assessment| render_facet_assessment(assessment) }.join("\n")}

        Treat expressed intent evidence, inferred fit, and demonstrated feasibility as distinct. Scores are advisory shadow-mode assessments and do not authorize work release. If a user challenges an interpretation, retain their explicit correction as new evidence and request reassessment.
      PROMPT
    end

    def current_facet_assessments
      FeatureIntentFacetAssessment.includes(feature_intent_facet_direction: :feature_intent_facet)
        .joins(feature_intent_facet_direction: :feature_intent_facet)
        .where(feature_intent_facets: { feature_intent_id: FeatureIntent.where(project: primary_project).select(:id) })
        .where(status: %w[completed unknown failed pending])
        .order(created_at: :desc).limit(20).to_a
        .select { |assessment| assessment.evidence_revision == assessment.feature_intent_facet_direction.feature_intent_facet.evidence_revision }
        .uniq(&:feature_intent_facet_direction_id)
    end

    def render_facet_assessment(assessment)
      direction = assessment.feature_intent_facet_direction
      [
        "- #{direction.feature_intent_facet.name} / #{direction.name}: #{assessment.status}",
        "  - Intent certainty: #{display_score(assessment.intent_score)}",
        "  - Technical confidence: #{display_score(assessment.technical_score)}",
        "  - Expressed intent evidence: #{assessment.evidence_references.join(", ").presence || "none cited"}",
        "  - Inferred fit: assessment interpretation — #{assessment.explanation}",
        "  - Demonstrated feasibility: technical score above; verify cited technical evidence before treating it as proof."
      ].join("\n")
    end

    def display_score(score) = score.nil? ? "unknown" : "#{score}/100"

    # @spec PROJECT-CREATION-010
    def project_setup_section
      "## Project Setup Needed\n\n" + Projects::BuildSetupPrompt.call(project: primary_project)
    end

    # @spec ONBOARD-CHAT-004
    def onboarding_setup_section
      <<~PROMPT.strip
        ## Onboarding Setup Interview

        This account still has setup work. Start by calling `get_onboarding_status`, `list_runners`, and `get_account_capabilities`; use their current state rather than guessing or re-asking completed steps. Adaptively ask what agent runners, GitHub repositories, and issue trackers (such as Linear) the user uses. After each completed action, summarize the remaining checklist. Offer `get_product_docs` whenever the user asks what a setting or feature means; use it as the authoritative product answer source, not memory. Provider choices are listed by `list_runners` and provider API key tools; explain the applicable provider options before recommending one. Always obtain the user's explicit approval before proposing a write tool. Write tools require human confirmation and must never be used to skip onboarding steps.
      PROMPT
    end

    def page_context
      context = chat_session.page_context
      return if context.blank?

      lines = []
      lines << "- URL: #{context["url"]}" if context["url"].present?
      lines << "- Path: #{context["path"]}" if context["path"].present?
      lines << "- Page title: #{context["page_title"]}" if context["page_title"].present?
      lines << "- Controller: #{context["controller"]}" if context["controller"].present?
      lines << "- Action: #{context["action"]}" if context["action"].present?
      lines << "- Project: #{context["project_name"]}" if context["project_name"].present?

      return if lines.empty?

      "## Current Page Context\n#{lines.join("\n")}"
    end

    def onboarding_incomplete?
      chat_session.account.onboarding_completed_at.blank?
    end

    # @spec QUESTION-EXPLORATION-001 @spec QUESTION-EXPLORATION-008 @spec QUESTION-EXPLORATION-013
    # @spec QUESTION-EXPLORATION-011 @spec FACET-CONFIDENCE-006 @spec FACET-CONFIDENCE-007
    # The pending questions are snapshotted into session metadata by
    # ClarifyingQuestions::OpenChat before the session row is inserted, so
    # this section never performs GitHub I/O while ChatSessions::Create's
    # insert transaction is open.
    # @spec QUESTION-EXPLORATION-016
    def clarifying_questions_context
      issue = exploration_issue
      questions = Array(chat_session.metadata&.dig("clarifying_questions"))
      progress_by_position = progress_by_position_for(questions)
      <<~PROMPT.strip
        #{feature_conversation_header}
        ## Clarifying Questions for #{issue.is_pull_request? ? "PR" : "Issue"} ##{issue.github_number}: #{issue.title}
        #{questions.each_with_index.map { |question, index| render_pending_question(question, index:, progress: progress_by_position[index + 1]) }.join("\n")}
        #{diagram_comment_context}
        Help the user explore these questions and ask focused follow-ups when needed. Before asking for facts, inspect available repository and Inbox context with the read-only tools. Choose the aid that the evidence makes useful; if the useful method is unclear, ask how the user wants to investigate. The user can redirect that method at any time. Use A/B questions only to distinguish plausible directions: always accept either direction, both, neither, conditions, and free-text alternatives. Do not treat a diagram click, selection, collapse, trial edit, or an assessment inference as a durable preference. A contextual answer applies only to its current question unless the user explicitly states a preference and explicitly chooses or clarifies its scope.

        A confirmed answer to one question can be saved with `save_clarifying_answer` and remains a draft: it does not post to GitHub or resolve the inbox item. Include useful human context from a temporary diagram or research finding when saving it. Once every question has a final answer, call `submit_clarifying_answers` with the answers in the displayed order. For a choice question, answer with one selection per line: the option's displayed text (extra rationale may follow), its number, or its letter, or an `Other: <description>` line when no option fits. That action posts the answers to GitHub and resolves this inbox item, so ask for confirmation through the tool rather than claiming it has been posted.
      PROMPT
    end

    # Human comments on a diagram are the discussion context the person added
    # when they selected an element. Each one carries the element text it was
    # made against, so it stays meaningful after the diagram is replaced or its
    # visual source released. Answer them as questions about the question, never
    # as confirmed decisions or durable preferences.
    # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-005
    def diagram_comment_context
      comments = recent_diagram_comments
      return "" if comments.empty?

      <<~PROMPT.strip
        ## Diagram comments

        #{comments.map { |comment| "- [#{comment.question_key}]#{diagram_comment_target(comment)} #{comment.body}" }.join("\n")}
      PROMPT
    end

    DIAGRAM_COMMENT_LIMIT = 20

    # @spec QUESTION-EXPLORATION-004
    def recent_diagram_comments
      ChatDiagramComment.where(chat_diagram_id: chat_session.chat_diagrams.select(:id))
        .order(:created_at, :id).last(DIAGRAM_COMMENT_LIMIT)
    end

    def diagram_comment_target(comment)
      comment.element_context.present? ? " (on #{comment.element_context})" : ""
    end

    # @spec QUESTION-EXPLORATION-018
    # A feature conversation names the feature whose issues share it, so the
    # assistant keeps the shared context in mind while answering the focused
    # issue's questions.
    def feature_conversation_header
      return "" unless chat_session.feature_intent

      "## Feature Conversation: #{chat_session.feature_intent.title}\n" \
        "All issues linked to this feature share this conversation.\n\n"
    end

    # @spec QUESTION-EXPLORATION-016
    # Choice questions are rendered with their canonical option lines (not the
    # folded `- ( ) Label) text` marker form stored in the snapshot) so the
    # assistant can echo a selectable string exactly as the validator accepts
    # it. Free-text questions render unchanged.
    def render_pending_question(question, index:, progress: nil)
      choices = ClarifyingQuestions::Choices.call(question: question)
      rendered = if choices.nil?
        "#{index + 1}. #{question}"
      else
        prose = question.split(ClarifyingQuestions::Choices::ANY_MARKER).first.to_s.strip
        option_lines = choices[:options].map do |option|
          "   - #{ClarifyingQuestions::ChoiceAnswers.option_line(label: option[:label], text: option[:text])}"
        end
        ([ "#{index + 1}. #{prose}" ] + option_lines).join("\n")
      end
      return rendered if progress&.answer.blank?

      "#{rendered}\n   - Saved draft answer: #{progress.answer}#{saved_evidence_context(progress)}"
    end

    # The evidence a person attached to a draft answer is durable human input,
    # not a preference. Reopening the conversation must restore it with the
    # answer so the reasoning behind the answer stays legible.
    # @spec QUESTION-EXPLORATION-013
    def saved_evidence_context(progress)
      return "" if progress.evidence_context.blank?

      "\n   - Human context recorded with that answer: #{progress.evidence_context}"
    end

    def progress_by_position_for(questions)
      digest = ClarifyingQuestions::SaveProgress.question_digest(questions)
      exploration_issue.clarifying_question_progresses
        .answered.where(question_digest: digest).ordered.index_by(&:position)
    end

    def cross_project_context
      summaries = reference_projects.map { |project| project_summary(project) }

      "## Referenced Projects\n\n#{summaries.join("\n\n")}"
    end

    def workspace_context
      parts = []
      parts << "## Workspace"
      parts << "You have access to a workspace with the project's git repository checked out."
      parts << "You can read and modify files, run commands, and execute git operations."

      ws = chat_session.metadata&.slice("current_branch", "git_status", "working_directory") || {}
      parts << "Current branch: #{ws["current_branch"]}" if ws["current_branch"].present?
      parts << "Git status:\n#{ws["git_status"]}" if ws["git_status"].present?
      parts << "Working directory: #{ws["working_directory"]}" if ws["working_directory"].present?

      parts.join("\n").strip
    end

    def user_preferences
      <<~PROMPT.strip
        ## Preferences
        Prefer concise, technical responses. Show code when relevant. Ask before making destructive changes.
      PROMPT
    end

    # @spec FACET-CONFIDENCE-007
    def explicit_preferences_section
      statements = explicit_preferences.map { |preference| "- #{preference.statement}" }
      "## Explicit Preferences\n\n#{statements.join("\n")}".strip
    end

    # --- Section helpers ---

    def readme_section(project)
      return nil unless project.respond_to?(:readme_content) && project.readme_content.present?

      content = truncate(project.readme_content, README_MAX_CHARS)
      "### Repository Overview\n#{content}"
    end

    def recent_issues_section(project)
      issues = project.issues
        .where(is_pull_request: false)
        .order(github_updated_at: :desc)
        .limit(RECENT_ISSUES_LIMIT)
        .select(:github_number, :title, :github_state)

      return nil if issues.empty?

      lines = issues.map do |issue|
        "- ##{issue.github_number}: #{issue.title} [#{issue.github_state}]"
      end

      "### Recent Issues\n#{lines.join("\n")}"
    end

    def recent_runs_section(project)
      runs = project.agent_runs
        .order(created_at: :desc)
        .limit(RECENT_RUNS_LIMIT)
        .select(:id, :goal, :status, :tokens_input, :tokens_output)

      return nil if runs.empty?

      lines = runs.map do |run|
        tokens = (run.tokens_input.to_i + run.tokens_output.to_i)
        "- Run ##{run.id}: #{run.goal} → #{run.status} (tokens: #{tokens})"
      end

      "### Recent Agent Runs\n#{lines.join("\n")}"
    end

    def style_guide_section(project)
      guides = StyleGuide.resolve_for(project).limit(3)
      return nil if guides.empty?

      contents = guides.filter_map(&:content_for_prompt)
      return nil if contents.empty?

      combined = contents.join("\n\n")
      combined = truncate(combined, STYLE_GUIDE_MAX_CHARS)

      "### Style Guide\n#{combined}"
    end

    def project_summary(project)
      desc = if project.respond_to?(:description) && project.description.present?
        truncate(project.description, CROSS_PROJECT_SUMMARY_MAX_CHARS)
      else
        "No description available"
      end

      "### #{project.owner}/#{project.repo}\n#{desc}"
    end

    # --- Data accessors ---

    def resolve_prompt
      if primary_project
        Prompt.resolve(CHAT_SYSTEM_PROMPT_SLUG, project: primary_project)
      else
        Prompt.active
          .where(slug: CHAT_SYSTEM_PROMPT_SLUG, project_id: nil)
          .where(account_id: [ chat_session.account_id, nil ])
          .order(Arel.sql("CASE WHEN account_id IS NOT NULL THEN 0 ELSE 1 END"))
          .first
      end
    end

    def primary_project
      @primary_project ||= chat_session.project
    end

    def explicit_preferences
      return ExplicitPreference.none unless chat_session.created_by

      @explicit_preferences ||= ExplicitPreferences::Context.call(
        owner: chat_session.created_by,
        project: primary_project,
        feature_intent: chat_session.feature_intent || exploration_issue&.feature_intent
      )
    end

    # @spec QUESTION-EXPLORATION-018
    # Resolves the issue the conversation currently focuses on: the linked
    # standalone issue, or the focus issue of a feature conversation.
    def exploration_issue
      chat_session.exploration_issue
    end

    def reference_projects
      @reference_projects ||= chat_session.chat_session_projects
        .where(context_type: "reference")
        .includes(:project)
        .map(&:project)
    end

    def mcp_tools
      @mcp_tools ||= load_mcp_tools
    end

    def load_mcp_tools
      project = primary_project
      return [] unless project

      project.mcp_server_definitions.enabled.map do |server|
        { name: server.name, description: server.metadata&.dig("description") || server.name }
      end
    end

    def truncate(text, max_chars)
      return text if text.length <= max_chars

      text[0, max_chars] + "..."
    end
  end
end
