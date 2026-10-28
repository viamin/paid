# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def recover
    turn = ChatTurn.find(params[:id])
    authorize turn.chat_session, :show?

    ChatSessions::RecoverStalledTurn.call(turn:, actor: current_user)
    redirect_to chat_session_path(turn.chat_session, anchor: "chat-message-#{turn.user_message_id}"), notice: "Recovery recorded. Send a new message to continue safely."
  end
end
