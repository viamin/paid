# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def recover
    chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
    authorize chat_session, :update?
    turn = chat_session.chat_turns.find(params[:id])

    recovered = ChatTurns::Recover.call(turn: turn, actor: current_user, expected_lock_version: params[:lock_version])
    redirect_to chat_session_path(chat_session), notice: recovered ? "Turn recovery started from its saved checkpoint." : "This turn is already being recovered or has changed."
  end
end
