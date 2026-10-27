# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }

  scope :incomplete, -> { where(status: %w[pending streaming]) }
  scope :inactive_before, ->(time) { where(last_activity_at: ...time) }

  def streaming?
    status == "streaming"
  end

  def stalled?
    status == "stalled"
  end

  def completed?
    status == "completed"
  end

  def failed?
    status == "failed"
  end

  # @spec CHAT-TURN-001
  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  # @spec CHAT-TURN-001
  def fail!(error:)
    update!(status: "failed", failed_at: Time.current, last_activity_at: Time.current,
      metadata: metadata.merge("error_class" => error.class.name))
  end

  def record_activity!(message: nil)
    update!(user_message: message || user_message, last_activity_at: Time.current)
  end
end
