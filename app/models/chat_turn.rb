# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  TERMINAL_STATUSES = %w[completed failed abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :detectable, ->(before) { where(status: %w[pending streaming]).where(activity_at: ...before) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def awaiting_confirmation?
    status == "awaiting_confirmation"
  end

  def stall!
    updated = self.class.where(id: id, status: %w[pending streaming]).update_all(status: "stalled", detected_at: Time.current, updated_at: Time.current)
    reload if updated.positive?
    updated.positive?
  end
end
