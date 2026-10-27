# frozen_string_literal: true

# @spec CHAT-API-027, CHAT-API-028
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_TIMEOUT = ENV.fetch("CHAT_TURN_STALL_TIMEOUT_SECONDS", 600).to_i.seconds

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :overdue, ->(now = Time.current) { unfinished.where(last_activity_at: ..(now - STALL_TIMEOUT)) }

  def mark_streaming!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def record_activity!
    update!(last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def await_confirmation!
    update!(status: "pending", last_activity_at: Time.current)
  end

  def stallable?(now: Time.current)
    unfinished? && overdue?(now) && !awaiting_confirmation? && !rate_limited? && !known_long_running?(now)
  end

  def stall!
    update!(status: "stalled", stalled_at: Time.current, failure_classification: "no_durable_activity")
  end

  private

  def unfinished?
    status.in?(%w[pending streaming])
  end

  def overdue?(now)
    last_activity_at <= now - STALL_TIMEOUT
  end

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def rate_limited?
    chat_session.rate_limited_until.present?
  end

  def known_long_running?(now)
    deadline = metadata["long_running_until"] if metadata.is_a?(Hash)
    deadline.present? && Time.iso8601(deadline) > now
  rescue ArgumentError
    false
  end
end
