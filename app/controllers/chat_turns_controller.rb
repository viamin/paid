# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  before_action :set_chat_session

  # @spec CHAT-TURN-RECOVERY-005 CHAT-TURN-RECOVERY-006
  def resume
    authorize ChatMessage.new(chat_session: @chat_session), :create?, policy_class: ChatMessagePolicy
    turn = @chat_session.chat_turns.find(params[:id])
    ChatSessions::ResumeStalledTurn.call(chat_turn: turn, actor: current_user)
    redirect_to chat_session_path(@chat_session), notice: "Recovery started from the last saved checkpoint."
  rescue ChatSessions::ResumeStalledTurn::RecoveryConflictError => e
    redirect_to chat_session_path(@chat_session), alert: e.message
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end
end
