# frozen_string_literal: true

class ChatTurns::DetectStalledSweepJob < ApplicationJob
  queue_as :maintenance

  BATCH_SIZE = 200

  def perform(now: Time.current)
    TenantContext.with_system_access do
      ChatTurn.incomplete.inactive_before(now - ChatTurns::DetectStalled::DEFAULT_THRESHOLD)
        .includes(:chat_session).find_each(batch_size: BATCH_SIZE) do |turn|
          ChatTurns::DetectStalled.call(turn: turn, now: now)
        end
    end
  end
end
