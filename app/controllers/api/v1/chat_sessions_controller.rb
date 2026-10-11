# frozen_string_literal: true

module Api
  module V1
    class ChatSessionsController < BaseController
      before_action -> { require_scope!(:chat) }
      before_action :set_chat_session, only: %i[show update destroy archive unarchive reopen]

      # @spec MOBILE-API-011 CHAT-API-001
      def index
        authorize ChatSession.new(account: current_account), :index?
        sessions = session_scope.includes(:project, :runner, :chat_session_projects, :projects)
          .order(updated_at: :desc, id: :desc)
        render json: { sessions: sessions.map { |session| session_json(session) } }
      end

      # @spec MOBILE-API-011 CHAT-API-001
      def create
        authorize ChatSession.new(account: current_account), :create?
        return validation_failed("container_capability is not supported by the mobile API") if params[:container_capability].present?

        session = ChatSessions::Create.call(account: current_account, user: current_user, **session_params)
        render json: session_json(session), status: :created
      rescue ArgumentError, ActiveRecord::RecordInvalid => error
        validation_failed(error.message)
      end

      def show
        authorize @chat_session
        render json: session_json(@chat_session)
      end

      def update
        authorize @chat_session
        @chat_session.update!(session_params)
        render json: session_json(@chat_session)
      rescue ActiveRecord::RecordInvalid => error
        validation_failed(error.message)
      end

      def destroy
        authorize @chat_session
        ChatSessions::Close.call(chat_session: @chat_session)
        head :no_content
      end

      def archive
        authorize @chat_session, :archive?
        ChatSessions::Archive.call(chat_session: @chat_session)
        render json: session_json(@chat_session.reload)
      end

      def unarchive
        authorize @chat_session, :unarchive?
        ChatSessions::Unarchive.call(chat_session: @chat_session)
        render json: session_json(@chat_session.reload)
      end

      def reopen
        authorize @chat_session, :reopen?
        ChatSessions::Reopen.call(chat_session: @chat_session)
        render json: session_json(@chat_session.reload)
      rescue ArgumentError => error
        validation_failed(error.message)
      end

      private

      def set_chat_session
        @chat_session = policy_scope(ChatSession).includes(:project, :runner, :chat_session_projects, :projects).find(params[:id])
      end

      def session_params
        params.permit(:model, :project_id, :runner_id, :title, :auto_approve, metadata: {}).to_h.symbolize_keys
      end

      def session_scope
        scoped = policy_scope(ChatSession)
        params[:archived] == "true" ? scoped.archived_only : scoped.visible
      end

      def validation_failed(message, details: {})
        render_error(:unprocessable_content, :validation_failed, message, details:)
      end

      def session_json(session)
        projects = (session.projects.to_a + [ session.project ].compact).uniq(&:id)
        {
          id: session.id, external_id: session.external_id, title: session.title, status: session.status,
          container_capability: session.container_capability, container_requested_at: session.container_requested_at,
          container_ready_at: session.container_ready_at, model: session.model, runner_id: session.runner_id,
          runner_name: session.runner&.display_name, project_id: session.project_id,
          project_name: session.project&.name || projects.first&.name, project_names: projects.map(&:name),
          auto_approve: session.auto_approve?, created_by_id: session.created_by_id,
          created_at: session.created_at, updated_at: session.updated_at,
          total_tokens_input: session.total_tokens_input, total_tokens_output: session.total_tokens_output,
          estimated_cost_cents: session.estimated_cost_cents
        }
      end
    end
  end
end
