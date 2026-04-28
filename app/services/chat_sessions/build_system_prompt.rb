# frozen_string_literal: true

module ChatSessions
  # Constructs a system prompt from session context including base identity,
  # project context, and workspace information.
  #
  # @example
  #   ChatSessions::BuildSystemPrompt.call(chat_session: session)
  #   # => "You are Paid, an AI development assistant..."
  class BuildSystemPrompt
    attr_reader :chat_session

    def initialize(chat_session:)
      @chat_session = chat_session
    end

    def self.call(...)
      new(...).call
    end

    def call
      sections = [ base_identity ]
      sections << paid_capabilities
      sections << primary_project_context if primary_project
      sections << cross_project_context if reference_projects.any?
      sections << workspace_context if chat_session.mode == "workspace"
      sections.compact.join("\n\n")
    end

    private

    def base_identity
      "You are Paid, an AI development assistant. You help users design, build, " \
        "debug, and manage software projects. Be concise, accurate, and proactive."
    end

    def paid_capabilities
      "You have access to Paid's tools for managing projects, agent runs, " \
        "code search, and account settings via MCP."
    end

    def primary_project_context
      project = primary_project
      parts = [ "## Primary Project: #{project.name}" ]
      parts << "Repository: #{project.repo_full_name}" if project.respond_to?(:repo_full_name) && project.repo_full_name.present?
      parts << "Description: #{project.description}" if project.respond_to?(:description) && project.description.present?
      parts.join("\n")
    end

    def cross_project_context
      names = reference_projects.map(&:name).join(", ")
      "## Reference Projects\nYou also have context from: #{names}"
    end

    def workspace_context
      "## Workspace Mode\nYou have access to a persistent workspace container. " \
        "You can read and write files, run commands, and make code changes directly."
    end

    # Primary project is the canonical project_id FK on ChatSession.
    # chat_session_projects is reserved for reference projects only.
    def primary_project
      @primary_project ||= chat_session.project
    end

    def reference_projects
      @reference_projects ||= chat_session.chat_session_projects
        .where(context_type: "reference")
        .includes(:project)
        .map(&:project)
    end
  end
end
