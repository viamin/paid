# frozen_string_literal: true

# Durable lifecycle record for one user-initiated chat turn. The transcript
# remains the evidence; this record makes its operational conclusion queryable.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :incomplete, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(at) { incomplete.where(last_activity_at: ...at) }

  def stream_message_id
    user_message.metadata.fetch("stream_message_id", user_message.external_id)
  end

  def stall_eligible?(at: Time.current)
    incomplete? && last_activity_at <= at - STALL_TIMEOUT &&
      !awaiting_confirmation? && !rate_limited? && !long_running_operation?
  end

  def replay_safe?
    chat_session.messages.where("id > ?", user_message_id).where.not(role: "system").none?
  end

  def incomplete?
    status.in?(%w[pending streaming])
  end

  private

  def awaiting_confirmation?
    chat_session.messages.pending_tool_confirmations.exists?
  end

  def rate_limited?
    chat_session.rate_limited_until&.future?
  end

  def long_running_operation?
    metadata["long_running_operation"] == true
  end
end
