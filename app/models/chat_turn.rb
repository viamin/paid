# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true

  scope :stale_candidates, ->(before) { where(status: ACTIVE_STATUSES).where("last_activity_at < ?", before) }

  def tool_activity?
    chat_session.messages.where("id > ?", user_message_id)
      .where("role = 'tool' OR NULLIF(BTRIM(tool_name), '') IS NOT NULL").exists?
  end

  def auto_recovery_safe?
    recovery_attempts.zero? && !tool_activity?
  end

  def replay_safe?
    failure_classification == "infrastructure_interruption" && !tool_activity?
  end

  def transition!(to, now: Time.current, **attributes)
    update!(**attributes.merge(status: to, last_activity_at: now, completed_at: terminal?(to) ? now : nil))
  end

  private

  def terminal?(value)
    %w[completed failed stalled abandoned].include?(value)
  end
end
