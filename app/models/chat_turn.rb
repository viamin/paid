# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-004
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage", optional: true
  belongs_to :actor, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :last_activity_at, presence: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def streaming? = status == "streaming"
  def stalled? = status == "stalled"
end
