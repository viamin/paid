# frozen_string_literal: true

module Api
  # Shared authentication for API endpoints called from agent containers.
  #
  # Validates that requests include a valid agent run ID and proxy token,
  # and that the referenced agent run is currently active.
  #
  # @example
  #   class Api::MyController < ActionController::API
  #     include Api::ContainerAuthentication
  #   end
  module ContainerAuthentication
    extend ActiveSupport::Concern
    AGENT_RUN_PROXY_CREDENTIAL_PREFIX = "paid-run".freeze
    KNOWLEDGE_RUN_PROXY_CREDENTIAL_PREFIX = "paid-knowledge-run".freeze
    CHAT_SESSION_PROXY_CREDENTIAL_PREFIX = "paid-chat-session".freeze

    included do
      class_attribute :knowledge_run_authentication_enabled, instance_accessor: false, default: false
      class_attribute :chat_session_authentication_enabled, instance_accessor: false, default: false

      around_action :with_container_tenant_context
      before_action :validate_container_request
      before_action :set_authenticated_run
      before_action :verify_proxy_token
    end

    class_methods do
      def allow_knowledge_run_authentication!
        self.knowledge_run_authentication_enabled = true
      end

      def allow_chat_session_authentication!
        self.chat_session_authentication_enabled = true
      end
    end

    private

    def with_container_tenant_context
      previous_account = Current.account
      previous_bypass = TenantContext.bypass_enabled?

      TenantContext.clear!
      yield
    ensure
      TenantContext.restore!(account: previous_account, bypass: previous_bypass)
    end

    def validate_container_request
      embedded_run_type, embedded_run_id, @embedded_proxy_token = extract_embedded_proxy_credentials
      header_run_type, header_run_id = extract_header_run_identity

      @authenticated_run_type = embedded_run_type || header_run_type
      @authenticated_run_id = embedded_run_id || header_run_id

      return if @authenticated_run_id.present?

      render json: { error: missing_run_id_error }, status: :unauthorized
    end

    def set_authenticated_run
      return if performed?

      @authenticated_run, error_message = TenantContext.with_system_access do
        case @authenticated_run_type
        when :chat_session
          @chat_session = ChatSession.includes(project: :account).find_by(id: @authenticated_run_id)
          [ @chat_session, "Invalid or inactive chat session" ]
        when :knowledge_run
          @knowledge_run = KnowledgeRun.includes(project: :account).find_by(id: @authenticated_run_id)
          [ @knowledge_run, "Invalid or inactive knowledge run" ]
        else
          @agent_run = AgentRun.includes(project: :account).find_by(id: @authenticated_run_id)
          [ @agent_run, "Invalid or inactive agent run" ]
        end
      end

      unless @authenticated_run&.active? || (@authenticated_run_type == :agent_run && @agent_run&.claimed?)
        render json: { error: error_message }, status: :forbidden
        return
      end

      TenantContext.apply!(authenticated_account)
    end

    def verify_proxy_token
      return if performed?

      provided_token = request.headers["X-Proxy-Token"] || @embedded_proxy_token

      unless provided_token.present?
        render(json: { error: "Invalid proxy token" }, status: :forbidden) and return
      end

      stored_token = @authenticated_run.ensure_proxy_token!

      unless ActiveSupport::SecurityUtils.secure_compare(provided_token, stored_token)
        render json: { error: "Invalid proxy token" }, status: :forbidden
      end
    end

    def extract_embedded_proxy_credentials
      parse_proxy_credential(request.headers["Authorization"]&.delete_prefix("Bearer ")) ||
        parse_proxy_credential(request.headers["X-Api-Key"]) ||
        parse_proxy_credential(request.headers["X-Goog-Api-Key"])
    end

    def extract_header_run_identity
      agent_run_id = request.headers["X-Agent-Run-Id"] || params[:agent_run_id]
      return [ :agent_run, agent_run_id ] if agent_run_id.present?

      knowledge_run_id = request.headers["X-Knowledge-Run-Id"] || params[:knowledge_run_id]
      return [ :knowledge_run, knowledge_run_id ] if knowledge_run_authentication_enabled? && knowledge_run_id.present?

      chat_session_id = request.headers["X-Chat-Session-Id"] || params[:chat_session_id]
      return [ :chat_session, chat_session_id ] if chat_session_authentication_enabled? && chat_session_id.present?

      [ nil, nil ]
    end

    def parse_proxy_credential(value)
      agent_run_match = value.to_s.match(/\A#{AGENT_RUN_PROXY_CREDENTIAL_PREFIX}:(\d+):([0-9a-f]+)\z/i)
      return [ :agent_run, agent_run_match[1], agent_run_match[2] ] if agent_run_match

      # Gate-after-match pattern: regex runs unconditionally for consistency across all
      # credential types, but the gate check ensures credentials are only accepted by
      # controllers that explicitly enable that authentication type. Unmatched credentials
      # fall through to nil safely.
      knowledge_run_match = value.to_s.match(/\A#{KNOWLEDGE_RUN_PROXY_CREDENTIAL_PREFIX}:(\d+):([0-9a-f]+)\z/i)
      return [ :knowledge_run, knowledge_run_match[1], knowledge_run_match[2] ] if knowledge_run_authentication_enabled? && knowledge_run_match

      chat_session_match = value.to_s.match(/\A#{CHAT_SESSION_PROXY_CREDENTIAL_PREFIX}:(\d+):([0-9a-f]+)\z/i)
      return [ :chat_session, chat_session_match[1], chat_session_match[2] ] if chat_session_authentication_enabled? && chat_session_match

      nil
    end

    def knowledge_run_authentication_enabled?
      self.class.knowledge_run_authentication_enabled
    end

    def chat_session_authentication_enabled?
      self.class.chat_session_authentication_enabled
    end

    def missing_run_id_error
      if chat_session_authentication_enabled?
        "Missing agent run ID, knowledge run ID, or chat session ID"
      elsif knowledge_run_authentication_enabled?
        "Missing agent run ID or knowledge run ID"
      else
        "Missing agent run ID"
      end
    end

    def authenticated_account
      @authenticated_run&.project&.account || @authenticated_run.try(:account)
    end

    def authenticated_project
      @authenticated_run&.project
    end
  end
end
