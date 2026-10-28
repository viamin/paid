# frozen_string_literal: true

# Runs one recovery attempt for a stalled or abandoned chat turn.
#
# @spec CHAT-TURN-RECOVERY-010
class ChatTurns::RecoverTurnJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(chat_turn_id:, actor_id: nil)
    turn = ChatTurn.find(chat_turn_id)
    actor = actor_id ? User.find_by(id: actor_id) : nil

    ChatTurns::Resume.call(turn: turn, actor: actor)
  end
end
