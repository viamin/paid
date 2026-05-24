# frozen_string_literal: true

module ChatSessions
  # Creates a new chat session with initial configuration, resolves
  # the provider/model, persists the system prompt as the first message,
  # and optionally associates a project.
  #
  # @example
  #   ChatSessions::Create.call(
  #     account: account,
  #     user: current_user,
  #     mode: "api",
  #     provider_id: provider.id,
  #     model: "gpt-4o"
  #   )
  class Create
    attr_reader :account, :user, :mode, :runner_id, :model,
      :project_id, :system_prompt, :title

    def initialize(account:, user:, mode: nil, runner_id: nil, provider_id: nil, model: nil,
      project_id: nil, system_prompt: nil, title: nil)
      @account = account
      @user = user
      @mode = mode.presence || "api"
      @runner_id = runner_id || provider_id
      @model = model
      @project_id = project_id
      @system_prompt = system_prompt
      @title = title
    end

    def self.call(...)
      new(...).call
    end

    alias_method :provider_id, :runner_id

    def call
      validate!

      ActiveRecord::Base.transaction do
        session = create_session
        prompt_text = build_system_prompt(session)
        persist_system_message(session, prompt_text)
        session
      end
    end

    private

    def validate!
      raise ArgumentError, "account is required" unless account
      raise ArgumentError, "user is required" unless user
      raise ArgumentError, "mode must be api or workspace" unless ChatSession::MODES.include?(mode)
    end

    def create_session
      ChatSession.create!(
        account: account,
        created_by: user,
        mode: mode,
        runner_id: resolved_runner&.id,
        model: resolved_model,
        project_id: project_id,
        system_prompt: system_prompt,
        title: title,
        status: "active",
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now,
        metadata: {}
      )
    end

    def build_system_prompt(session)
      return system_prompt if system_prompt.present?

      ChatSessions::BuildSystemPrompt.call(chat_session: session)
    end

    def persist_system_message(session, prompt_text)
      session.messages.create!(
        role: "system",
        content: prompt_text
      )
    end

    def resolved_runner
      @resolved_runner ||= if runner_id.present?
        Runner.kept_only.find(runner_id).tap do |runner|
          unless runner.user&.account_id == account.id
            raise ArgumentError, "runner must belong to the same account"
          end
          raise ArgumentError, "runner must be enabled for chat" unless runner.enabled_for_chat?
        end
      else
        default_runner_for_user
      end
    end

    def resolved_model
      return model if model.present?

      runner = resolved_runner
      return nil unless runner

      LlmModel.active.by_provider(runner.runner_key).by_capability.first&.model_id
    end

    def default_runner_for_user
      Runner.first_chat_enabled_for_owner(user)
    end
  end
end
