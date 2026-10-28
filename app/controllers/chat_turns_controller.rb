# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def request_recovery
    chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
    authorize ChatMessage.new(chat_session:), :create?, policy_class: ChatMessagePolicy
    turn = chat_session.chat_turns.find(params[:id])

    if turn.request_recovery!
      redirect_to chat_session_path(chat_session), notice: "Recovery review requested. No tool calls were replayed."
    else
      redirect_to chat_session_path(chat_session), alert: "Recovery was already requested or this turn is no longer stalled."
    end
  end
end
