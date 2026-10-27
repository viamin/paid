# frozen_string_literal: true

class ChatTurnsController < ApplicationController
  def recover
    turn = policy_scope(ChatTurn).find(params[:id])
    authorize turn
    ChatTurns::RequestRecovery.call(chat_turn: turn, actor: current_user, confirmed: params[:confirmed] == "true")
    head :accepted
  rescue ChatTurns::RequestRecovery::StaleTurnError, ChatTurns::RequestRecovery::ConfirmationRequiredError => error
    render json: { error: error.message }, status: :conflict
  end
end
