# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :initiating_message_id, uniqueness: true

  scope :stale, ->(timeout:) { where(status: "streaming").where(last_activity_at: ...timeout.ago) }

  def long_running?
    until_at = metadata.is_a?(Hash) && metadata["long_running_until"]
    until_at.present? && Time.iso8601(until_at) > Time.current
  rescue ArgumentError
    false
  end

  def heartbeat!
    update!(last_activity_at: Time.current)
  end
end
