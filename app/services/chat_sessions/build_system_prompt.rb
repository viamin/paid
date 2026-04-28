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
      sections << { priority: 1, content: project_context } if primary_project
      sections << { priority: 2, content: tool_definitions } if mcp_tools.any?
      sections << { priority: 3, content: cross_project_context } if reference_projects.any?
      sections << { priority: 4, content: workspace_context } if chat_session.mode == "workspace"
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

    def base_identity
      <<~PROMPT.strip
        You are an AI assistant helping manage software projects via Paid, a platform for AI-driven development.
        You can help with:
        - Designing features and discussing implementation approaches
        - Debugging issues by inspecting code, logs, and running commands
        - Managing projects, issues, and agent runs through Paid's tools
        - Answering questions about codebases and project status

        When the user asks you to perform actions (trigger runs, list projects, etc.), use the available tools.
        Be concise and technical. Ask clarifying questions when the request is ambiguous.
      PROMPT
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

    def primary_project
      @primary_project ||= chat_session.project
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
