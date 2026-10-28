# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  before_action :set_chat_session

  # @spec CHAT-TURN-RECOVERY-004 CHAT-TURN-RECOVERY-006
  def recover
    authorize @chat_session, :update?
    turn = @chat_session.chat_turns.find(params[:id])
    ChatTurns::Recover.call(turn:, actor: current_user, revision: params.require(:revision),
      confirmed: ActiveModel::Type::Boolean.new.cast(params[:confirmed]))
    redirect_to chat_session_path(@chat_session), notice: "Turn recovery started from the saved checkpoint."
  rescue ChatTurns::StaleRevision, ChatTurns::RecoveryConfirmationRequired, ArgumentError => error
    redirect_to chat_session_path(@chat_session), alert: error.message
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end
end
