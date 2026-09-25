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
      sections << { priority: 0, content: base_identity }
      sections << { priority: 1, content: page_context } if page_context.present?
      sections << { priority: 1, content: project_context } if primary_project
      sections << { priority: 1, content: clarifying_questions_context } if clarifying_question_issue
      # @spec PROJECT-CREATION-010 — a fresh (blank) project needs its setup
      # interview surfaced in every chat started against it, so setup can also
      # happen from a plain new chat session.
      sections << { priority: 1, content: project_setup_section } if primary_project&.setup_pending?
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

    # @spec PROJECT-CREATION-010
    def project_setup_section
      "## Project Setup Needed\n\n" + Projects::BuildSetupPrompt.call(project: primary_project)
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

    # @spec QUESTION-EXPLORATION-001
    # The pending questions are snapshotted into session metadata by
    # ClarifyingQuestions::OpenChat before the session row is inserted, so
    # this section never performs GitHub I/O while ChatSessions::Create's
    # insert transaction is open.
    def clarifying_questions_context
      issue = clarifying_question_issue
      questions = Array(chat_session.metadata&.dig("clarifying_questions"))
      <<~PROMPT.strip
        ## Clarifying Questions for #{issue.is_pull_request? ? "PR" : "Issue"} ##{issue.github_number}: #{issue.title}
        #{questions.each_with_index.map { |question, index| "#{index + 1}. #{question}" }.join("\n")}

        Help the user explore these questions and ask focused follow-ups when needed. Once every question has a final answer, call `submit_clarifying_answers` with the answers in the displayed order. That action posts the answers to GitHub and resolves this inbox item, so ask for confirmation through the tool rather than claiming it has been posted.
      PROMPT
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

    def clarifying_question_issue
      chat_session.clarifying_question_issue
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
