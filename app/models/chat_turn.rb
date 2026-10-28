# frozen_string_literal: true

# @spec CHAT-API-027 CHAT-API-028 CHAT-API-029
class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  TERMINAL_STATUSES = %w[completed failed abandoned].freeze

  belongs_to :account
  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  belongs_to :checkpoint_message, class_name: "ChatMessage", optional: true
  belongs_to :recovered_by, class_name: "User", optional: true

  validates :stream_id, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :last_activity_at, presence: true

  scope :incomplete, -> { where(status: %w[pending streaming]) }
  scope :inactive_before, ->(time) { where(last_activity_at: ...time) }

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def awaiting_confirmation?
    metadata["awaiting_confirmation"] == true
  end
end
