# frozen_string_literal: true

# A server-side conclusion for one accepted chat request. Message rows are
# evidence within the turn; this record is the durable lifecycle and recovery
# boundary.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  TERMINAL_STATUSES = %w[completed failed abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :terminal_message, class_name: "ChatMessage", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :user_message, presence: true
  validate :user_message_belongs_to_chat_session

  scope :detectable, -> { where(status: %w[pending streaming]) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def touch_activity!
    update!(last_activity_at: Time.current) unless terminal?
  end

  def complete!(message)
    update!(status: "completed", terminal_message: message, completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", classification:, completed_at: Time.current, last_activity_at: Time.current)
  end

  private

  def user_message_belongs_to_chat_session
    return if user_message.blank? || user_message.chat_session_id == chat_session_id

    errors.add(:user_message, "must belong to the chat session")
  end
end
