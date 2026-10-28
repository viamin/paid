# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def resume
    chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
    authorize ChatMessage.new(chat_session:), :create?, policy_class: ChatMessagePolicy
    turn = chat_session.chat_turns.find(params[:id])
    ChatTurns::Resume.call(chat_turn: turn, actor: current_user,
      expected_revision: params.require(:expected_revision))

    redirect_to chat_session_path(chat_session), notice: "The turn was queued to resume from its saved checkpoint."
  rescue ActiveRecord::StaleObjectError, ArgumentError => error
    redirect_to chat_session_path(chat_session), alert: error.message
  end
end
