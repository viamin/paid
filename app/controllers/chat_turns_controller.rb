# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def recover
    turn = ChatTurn.for_visible_sessions(current_user).find(params[:id])
    authorize turn.user_message, :create?, policy_class: ChatMessagePolicy

    ChatTurns::Recover.call(turn:, actor: current_user)
    redirect_to chat_session_path(turn.chat_session), notice: "The stalled request is being retried. Review any tool confirmations before approving them."
  rescue ChatTurns::Recover::NotRecoverable => e
    redirect_to chat_session_path(turn.chat_session), alert: e.message
  end
end
