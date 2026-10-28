# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def resume
    turn = policy_scope(ChatSession).find(params[:chat_session_id]).chat_turns.find(params[:id])
    authorize ChatMessage.new(chat_session: turn.chat_session), :create?, policy_class: ChatMessagePolicy
    ChatTurns::Resume.call(turn: turn, actor: current_user, expected_revision: params.require(:revision))
    redirect_to chat_session_path(turn.chat_session), notice: "Turn recovery queued from its last durable checkpoint."
  rescue ChatTurns::Resume::ConflictError => e
    redirect_to chat_session_path(turn.chat_session), alert: e.message
  end
end
