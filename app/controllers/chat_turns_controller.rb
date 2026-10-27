# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def resume
    turn = policy_scope(ChatTurn).find(params[:id])
    authorize turn
    ChatSessions::Turns::Recover.call(turn:, actor: current_user, revision: params[:revision], confirmed: params[:confirmed] == "true")
    redirect_to chat_session_path(turn.chat_session), notice: "Recovery started from the last durable checkpoint."
  rescue ChatSessions::Turns::Recover::Conflict, ChatSessions::Turns::Recover::ConfirmationRequired => error
    redirect_to chat_session_path(turn.chat_session), alert: error.message
  end
end
