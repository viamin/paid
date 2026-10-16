# frozen_string_literal: true

class ChatDiagramCommentsController < ApplicationController
  before_action :set_chat_session
  before_action :set_diagram

  rate_limit to: ChatMessages::RateLimit::MAX_REQUESTS, within: ChatMessages::RateLimit::PERIOD,
    by: -> { ChatMessages::RateLimit.identifier(user_id: current_user&.id, chat_session_id: params[:chat_session_id]) },
    with: -> { redirect_to chat_session_path(params[:chat_session_id]), alert: "Rate limit exceeded" },
    only: :create

  # @spec QUESTION-EXPLORATION-004 QUESTION-EXPLORATION-006 QUESTION-EXPLORATION-012
  def create
    authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
    ChatDiagrams::Comment.call(diagram: @diagram, actor: current_user, body: params[:body], element_id: params[:element_id])
    redirect_back fallback_location: chat_session_path(@chat_session), notice: "Diagram comment added."
  rescue ChatDiagrams::Comment::StaleElementError => error
    redirect_back fallback_location: chat_session_path(@chat_session), alert: error.message
  rescue ActiveRecord::RecordInvalid => error
    redirect_back fallback_location: chat_session_path(@chat_session), alert: error.record.errors.full_messages.to_sentence
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def set_diagram
    @diagram = @chat_session.chat_diagrams.find(params[:chat_diagram_id])
  end
end
