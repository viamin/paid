# frozen_string_literal: true

module ChatSessions
  # Adds project knowledge to an existing chat session by creating a
  # ChatSessionProject association and injecting a context system message.
  #
  # @example
  #   ChatSessions::AddProjectContext.call(
  #     chat_session: session,
  #     project: project,
  #     context_type: "reference"
  #   )
  class AddProjectContext
    attr_reader :chat_session, :project, :context_type

    def initialize(chat_session:, project:, context_type: "reference")
      @chat_session = chat_session
      @project = project
      @context_type = context_type
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!

      ActiveRecord::Base.transaction do
        association = create_association
        inject_context_message
        association
      end
    end

    private

    def validate!
      raise ArgumentError, "chat session must be active" unless chat_session.status == "active"
      raise ArgumentError, "context_type must be primary or reference" unless ChatSessionProject::CONTEXT_TYPES.include?(context_type)

      return unless chat_session.chat_session_projects.exists?(project_id: project.id)

      raise ArgumentError, "project is already associated with this session"
    end

    def create_association
      chat_session.chat_session_projects.create!(
        project: project,
        context_type: context_type
      )
    end

    def inject_context_message
      chat_session.messages.create!(
        role: "system",
        content: build_context_content
      )
    end

    def build_context_content
      parts = [ "## Added Project Context: #{project.name}" ]
      parts << "Type: #{context_type}"
      parts << "Repository: #{project.repo_full_name}" if project.respond_to?(:repo_full_name) && project.repo_full_name.present?
      parts << "Description: #{project.description}" if project.respond_to?(:description) && project.description.present?
      parts.join("\n")
    end
  end
end
