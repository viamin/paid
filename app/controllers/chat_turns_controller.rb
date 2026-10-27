# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def retry
    chat_turn = ChatTurn.find(params[:id])
    authorize chat_turn.chat_session, :show?, policy_class: ChatSessionPolicy
    ChatSessions::RetryStalledTurn.call(chat_turn:, actor: current_user, lock_version: params[:lock_version])
    redirect_to chat_session_path(chat_turn.chat_session), notice: "Recovery queued."
  rescue ActiveRecord::StaleObjectError, ArgumentError
    redirect_to chat_session_path(chat_turn.chat_session), alert: "This recovery request was already handled. Refresh the transcript."
  end
end
