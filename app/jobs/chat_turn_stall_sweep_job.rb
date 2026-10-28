# frozen_string_literal: true

class ChatTurnStallSweepJob < ApplicationJob
  queue_as :maintenance

  DEFAULT_THRESHOLD = 15.minutes

  # @spec CHAT-TURN-RECOVERY-002 CHAT-TURN-RECOVERY-003 CHAT-TURN-RECOVERY-004
  def perform(now: Time.current, threshold: configured_threshold)
    cutoff = now - threshold
    TenantContext.with_system_access do
      ChatTurn.stale_candidates(cutoff).find_each do |turn|
        classify(turn, now, cutoff)
      end
    end
  end

  private

  def classify(turn, detected_at, cutoff)
    notice = nil
    turn.with_lock do
      turn.reload
      return unless turn.status.in?(%w[pending streaming]) && turn.pause_reason.nil?
      return unless turn.last_activity_at < cutoff

      side_effects = side_effecting_results(turn)
      turn.update!(status: "stalled", classification: "activity_timeout",
        detected_stalled_at: detected_at, side_effects_completed: side_effects.any?)
      notice = persist_notice(turn, side_effects)
    end
    broadcast_notice(turn, notice) if notice
    log_detection(turn)
  end

  def side_effecting_results(turn)
    turn.messages.where(role: "tool").select do |message|
      Tools::Registry.write_tool?(message.tool_name)
    end
  end

  def persist_notice(turn, side_effects)
    return if turn.messages.where("metadata ->> 'stalled_turn_notice' = 'true'").exists?

    turn.messages.create!(chat_session: turn.chat_session, role: "system",
      content: notice_content(side_effects), metadata: notice_metadata(turn, side_effects))
  end

  def notice_content(side_effects)
    evidence = if side_effects.any?
      "#{side_effects.size} side-effecting tool #{'result'.pluralize(side_effects.size)} may have completed"
    else
      "No completed side-effecting tool result was recorded"
    end
    "This chat turn stopped without a final assistant response. #{evidence}; the final outcome remains unknown. " \
      "Review the preserved tool details below, then choose Resume to continue from this checkpoint. Resume requires " \
      "your confirmation because unrecorded external effects cannot be ruled out."
  end

  def notice_metadata(turn, side_effects)
    { "stalled_turn_notice" => true, "chat_turn_id" => turn.id,
     "turn_revision" => turn.lock_version, "tool_message_ids" => side_effects.map(&:id) }
  end

  def broadcast_notice(turn, notice)
    ActionCable.server.broadcast("chat_session:#{turn.chat_session_id}", {
      type: "message_created", message_id: notice.id, role: notice.role,
      html: ApplicationController.render(partial: "chat_messages/message", locals: { message: notice })
    })
  end

  def log_detection(turn)
    Rails.logger.warn(message: "chat_turn.stalled", chat_session_id: turn.chat_session_id,
      chat_turn_id: turn.id, classification: turn.classification,
      side_effects_completed: turn.side_effects_completed)
  end

  def configured_threshold
    Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_THRESHOLD.to_i)).seconds
  rescue ArgumentError
    DEFAULT_THRESHOLD
  end
end
