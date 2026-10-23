# frozen_string_literal: true

module Api
  module V1
    class ChatDiagramCommentsController < BaseController
      before_action -> { require_scope!(:chat) }
      before_action :set_chat_session
      before_action :set_diagram

      # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-006 QUESTION-EXPLORATION-012
      def create
        authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
        comment = ChatDiagrams::Comment.call(diagram: @diagram, actor: current_user, body: params[:body], element_id: params[:element_id])
        render json: ChatDiagrams::CommentSerializer.call(comment), status: :created
      rescue ChatDiagrams::Comment::StaleElementError => error
        render_error(:unprocessable_content, :stale_element, error.message)
      rescue ActiveRecord::RecordInvalid => error
        render_error(:unprocessable_content, :validation_failed, error.record.errors.full_messages.to_sentence)
      end

      private

      def set_chat_session
        @chat_session = policy_scope(ChatSession).find(params[:session_id])
      end

      def set_diagram
        @diagram = @chat_session.chat_diagrams.find(params[:diagram_id])
      end
    end
  end
end
