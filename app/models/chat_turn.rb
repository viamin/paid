# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-001 CHAT-TURN-002
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_AFTER = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :detectable, ->(now = Time.current) { where(status: %w[pending streaming]).where(activity_at: ..(now - STALL_AFTER)) }

  def start!
    update!(status: "streaming", activity_at: Time.current)
  end

  def checkpoint!
    update!(activity_at: Time.current) unless terminal?
  end

  def complete!(outcome:)
    update!(status: "completed", activity_at: Time.current, metadata: metadata.merge("outcome" => outcome))
  end

  def fail!(classification:)
    update!(status: "failed", activity_at: Time.current, failure_classification: classification)
  end

  def stall!
    update!(status: "stalled", detection_at: Time.current, recovery_state: "confirmation_required")
  end

  def stallable?
    !chat_session.messages.pending_tool_confirmations.exists? && !chat_session.rate_limited?
  end

  def terminal?
    status.in?(%w[completed failed stalled abandoned])
  end
end
