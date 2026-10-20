# frozen_string_literal: true

module Api
  module V1
    class ChatInvestigationsController < BaseController
      before_action -> { require_scope!(:chat) }
      before_action :set_chat_session
      before_action :set_investigation, only: %i[show cancel]

      # @spec QUESTION-EXPLORATION-012
      def index
        authorize ChatMessage.new(chat_session: @chat_session), :index?, policy_class: ChatMessagePolicy
        render json: { investigations: @chat_session.chat_investigations.includes(:clarifying_question_progress).order(created_at: :desc).map { |item| investigation_json(item) } }
      end

      # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-012
      def create
        authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
        authorize @chat_session.project, :explore?
        ensure_exploration_enabled!
        result = ChatInvestigations::Start.call(question: question, actor: current_user, **investigation_params)
        render json: investigation_json(result.investigation), status: :created
      rescue ArgumentError, ActiveRecord::RecordInvalid => error
        render_error(:unprocessable_content, :validation_failed, error.message)
      end

      def show
        authorize ChatMessage.new(chat_session: @chat_session), :index?, policy_class: ChatMessagePolicy
        render json: investigation_json(@investigation)
      end

      def cancel
        authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
        authorize @chat_session.project, :explore?
        render json: investigation_json(ChatInvestigations::Cancel.call(investigation: @investigation, actor: current_user))
      end

      private

      def set_chat_session
        @chat_session = policy_scope(ChatSession).find(params[:session_id])
      end

      def set_investigation
        @investigation = @chat_session.chat_investigations.find(params[:id])
      end

      def question
        @chat_session.clarifying_question_issue.clarifying_question_progresses.find_by!(position: params.require(:position))
      end

      def investigation_params
        params.permit(:kind, :prompt, :estimated_cost_cents).to_h.symbolize_keys
      end

      def ensure_exploration_enabled!
        raise Pundit::NotAuthorizedError, "Question exploration is not enabled for this project" unless FeatureFlags.enabled?(:question_exploration, project: @chat_session.project)
      end

      def investigation_json(investigation)
        {
          id: investigation.id, question_position: investigation.clarifying_question_progress.position,
          kind: investigation.kind, status: investigation.status, result: investigation.result,
          authorization_required: investigation.awaiting_authorization?, created_at: investigation.created_at,
          started_at: investigation.started_at, finished_at: investigation.finished_at, cancelled_at: investigation.cancelled_at
        }
      end
    end
  end
end
