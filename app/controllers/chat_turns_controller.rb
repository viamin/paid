# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  before_action :set_chat_session

  # @spec CHAT-TURN-RECOVERY-004
  def resume
    authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
    turn = @chat_session.chat_turns.find(params[:id])
    ChatTurns::RequestRecovery.call(turn:, actor: current_user)
    ChatTurns::ResumeJob.perform_later(chat_turn_id: turn.id, actor_id: current_user.id)
    redirect_to @chat_session, notice: "Recovery started from the last durable checkpoint."
  rescue ChatTurns::RequestRecovery::ConflictError => e
    redirect_to @chat_session, alert: e.message
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end
end
