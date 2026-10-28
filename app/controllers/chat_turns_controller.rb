# frozen_string_literal: true

# Recovery of a stalled or abandoned chat turn. The action is the explicit
# confirmation the stall notice asks for: it authorizes the recovery, claims
# the turn's single recovery slot, and hands the turn to the recovery job.
#
# @spec CHAT-TURN-RECOVERY-012
class ChatTurnsController < ApplicationController
  before_action :set_chat_session
  before_action :set_chat_turn

  def recover
    authorize @chat_turn, :recover?, policy_class: ChatTurnPolicy

    if stale_revision?
      respond_with_conflict
      return
    end

    result = ChatTurns::RequestRecovery.call(turn: @chat_turn, actor: current_user, source: :user)

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), notice: message_for(result) }
      format.json { render json: { status: result.status, message: message_for(result) } }
    end
  end

  private

  def set_chat_session
    @chat_session = policy_scope(ChatSession).find(params[:chat_session_id])
  end

  def set_chat_turn
    @chat_turn = @chat_session.chat_turns.find(params[:id])
  end

  # A notice rendered before the turn changed no longer describes it. Acting on
  # a stale revision is refused instead of recovering a turn the user did not
  # see.
  def stale_revision?
    expected = params[:revision]
    return false if expected.blank?

    expected.to_i != @chat_turn.revision
  end

  def respond_with_conflict
    message = "This turn changed since the notice was rendered. Reload the conversation to see its current state."

    respond_to do |format|
      format.html { redirect_to chat_session_path(@chat_session), alert: message }
      format.json { render json: { error: message }, status: :conflict }
    end
  end

  def message_for(result)
    case result.status
    when ChatTurns::RequestRecovery::STARTED then "Resuming the stalled turn."
    when ChatTurns::RequestRecovery::DUPLICATE then "A recovery attempt is already running for this turn."
    when ChatTurns::RequestRecovery::EXHAUSTED then "This turn already used its recovery budget. Start a new message to continue."
    when ChatTurns::RequestRecovery::CONFIRMATION_REQUIRED then "This turn needs an explicit confirmation before it can be recovered."
    else "This turn has no stalled state to recover."
    end
  end
end
