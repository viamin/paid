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
  #     container_capability: "none",
  #     provider_id: provider.id,
  #     model: "gpt-4o"
  #   )
  class Create
    attr_reader :account, :user, :container_capability, :runner_id, :model,
      :project_id, :system_prompt, :title, :metadata, :auto_approve,
      :inbox_item_key, :inbox_item_metadata, :opened_at, :clarifying_question_issue, :feature_intent

    def initialize(account:, user:, container_capability: nil, runner_id: nil, provider_id: nil, model: nil,
      project_id: nil, system_prompt: nil, title: nil, metadata: nil, auto_approve: nil,
      inbox_item_key: nil, inbox_item_metadata: nil, opened_at: nil, clarifying_question_issue: nil,
      feature_intent: nil)
      @account = account
      @user = user
      @container_capability_param = container_capability
      @container_capability = container_capability.presence || "none"
      @runner_id = runner_id || provider_id
      @model = model
      @project_id = project_id
      @system_prompt = system_prompt
      @title = title
      @metadata = metadata
      @auto_approve = auto_approve
      @inbox_item_key = inbox_item_key
      @inbox_item_metadata = inbox_item_metadata
      @opened_at = opened_at
      @clarifying_question_issue = clarifying_question_issue
      @feature_intent = feature_intent
      @configured_personal_draft = explicitly_configured_personal_draft?
    end

    def self.call(...)
      new(...).call
    end

    alias_method :provider_id, :runner_id

    def call
      # @spec CHAT-API-001 CHAT-API-030
      validate!

      session, enqueue_provisioning = create_or_reuse_session

      enqueue_background_provisioning(session) if enqueue_provisioning
      session
    end

    private

    def validate!
      raise ArgumentError, "account is required" unless account
      raise ArgumentError, "user is required" unless user
      unless ChatSession::REQUESTABLE_CONTAINER_CAPABILITIES.include?(container_capability)
        raise ArgumentError,
          "container_capability must be one of #{ChatSession::REQUESTABLE_CONTAINER_CAPABILITIES.join(', ')}"
      end
    end

    def create_session
      ChatSession.create!(
        account: account,
        created_by: user,
        container_capability: initial_container_capability,
        container_requested_at: container_requested_at,
        runner_id: resolved_runner&.id,
        model: resolved_model,
        project_id: project_id,
        clarifying_question_issue: clarifying_question_issue,
        feature_intent: feature_intent,
        system_prompt: system_prompt,
        title: title,
        status: "active",
        idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now,
        metadata: session_metadata,
        auto_approve: auto_approve || false,
        inbox_item_key: inbox_item_key,
        inbox_item_metadata: inbox_item_metadata.presence || {},
        opened_at: opened_at
      )
    end

    # @spec CHAT-API-030
    def create_or_reuse_session
      return create_new_session unless reusable_personal_draft?

      user.with_lock { create_or_reuse_personal_draft }
    end

    def create_or_reuse_personal_draft
      attempts = 0
      begin
        attempts += 1
        create_new_session(requires_new: true)
      rescue ActiveRecord::RecordNotUnique
        reconcile_existing_personal_draft
      rescue ActiveRecord::RecordNotFound
        retry if attempts < 2

        raise
      end
    end

    def create_new_session(requires_new: false)
      ActiveRecord::Base.transaction(requires_new:) do
        created = create_session
        persist_system_message(created, build_system_prompt(created))
        [ created, true ]
      end
    end

    def reusable_personal_draft?
      title.blank? && inbox_item_key.blank? && clarifying_question_issue.blank? && feature_intent.blank?
    end

    def explicitly_configured_personal_draft?
      [ runner_id, model, project_id, system_prompt, metadata ].any?(&:present?) ||
        container_capability == "pending" || auto_approve_enabled?
    end

    def auto_approve_enabled?
      ActiveModel::Type::Boolean.new.cast(auto_approve)
    end

    def existing_personal_draft
      ChatSession.unstarted_untitled_personal.where(account:, created_by: user).order(created_at: :desc, id: :desc).first!
    end

    def reconcile_existing_personal_draft
      draft = existing_personal_draft
      return [ draft, false ] unless @configured_personal_draft

      enqueue_provisioning = false
      draft.with_lock do
        enqueue_provisioning = !draft.container_pending? && initial_container_capability == "pending"
        draft.update!(draft_configuration)
        draft.messages.find_by!(role: "system").update!(content: build_system_prompt(draft))
      end
      [ draft, enqueue_provisioning ]
    end

    def draft_configuration
      {
        runner_id: resolved_runner&.id,
        model: resolved_model,
        project_id: project_id,
        system_prompt: system_prompt,
        metadata: session_metadata,
        auto_approve: auto_approve || false
      }.merge(container_configuration)
    end

    def container_configuration
      return {} if @container_capability_param.blank?

      {
        container_capability: initial_container_capability,
        container_requested_at: container_requested_at
      }
    end

    def container_requested_at
      return unless ChatSession::CONTAINER_REQUESTED_CAPABILITIES.include?(initial_container_capability)

      Time.current
    end

    # Provisioning runs in the background (RDR-037) so the first inline message
    # is never blocked. Only sessions that requested a container ("pending")
    # are provisioned, and only when eager provisioning is enabled for the
    # account. Accounts that defer provisioning start inline-only so the first
    # container-only tool call can win the existing none/stopped -> pending lazy
    # transition instead of leaving the session permanently pending.
    #
    # @spec CHAT-CONTAINER-PROVISIONING-001
    # @spec CHAT-CONTAINER-PROVISIONING-005
    def enqueue_background_provisioning(session)
      return unless session.container_pending?
      return unless eager_provisioning_enabled?

      ChatSessions::ProvisionContainerJob.perform_later(
        chat_session_id: session.id,
        account_id: account.id
      )
    rescue GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError
      enqueue_pending_provision_recheck
      Rails.logger.info(
        message: "chat_sessions.create.provision_container_job_deferred",
        chat_session_id: session.id,
        account_id: account.id
      )
    end

    def eager_provisioning_enabled?
      account.tenant_setting&.chat_eager_provisioning != false
    end

    def initial_container_capability
      return container_capability if eager_provisioning_enabled?
      return "none" if ChatSession::CONTAINER_REQUESTED_CAPABILITIES.include?(container_capability)

      container_capability
    end

    def enqueue_pending_provision_recheck
      ChatSessions::ReenqueuePendingProvisionJob.perform_later(account_id: account.id)
    rescue GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError
      nil
    end

    def build_system_prompt(session)
      return system_prompt if system_prompt.present?

      ChatSessions::BuildSystemPrompt.call(chat_session: session)
    end

    def persist_system_message(session, prompt_text)
      # @spec CHAT-API-001
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
          unless ChatSessions::BuildLlmClient.usable_runner?(runner)
            raise ArgumentError, "runner must be an API-key chat runner with a configured API key"
          end
        end
      else
        default_runner_for_user
      end
    rescue ActiveRecord::RecordNotFound
      raise ArgumentError, "runner must belong to the same account"
    end

    def resolved_model
      # @spec CHAT-API-018
      # @spec CHAT-API-026
      return model if model.present?

      runner = resolved_runner
      return nil unless runner
      return nil if runner.free_model_policy?

      curated_model_for(runner).model_id
    end

    def session_metadata
      return metadata.presence || {} if model.present? || resolved_runner.nil?
      return metadata.presence || {} if resolved_runner.free_model_policy?

      (metadata.presence || {}).merge("model_tier" => curated_model_for(resolved_runner).tier)
    end

    def curated_model_for(runner)
      # @spec CHAT-API-026
      resolution = CuratedModelOptions.resolve_with_diagnostics(runner:, projects: policy_projects)
      return resolution.option if resolution.option

      raise ModelUnavailableError.new(runner:, rejection_reasons: resolution.rejection_reasons)
    end

    def policy_projects
      @policy_projects ||= account.projects.where(id: project_id).to_a
    end

    def default_runner_for_user
      Runner.first_configured_chat_enabled_for_owner(user)
    end
  end
end
