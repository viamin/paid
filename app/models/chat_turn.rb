# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true, allow_nil: true

  scope :detectable, -> { where(status: ACTIVE_STATUSES) }
end
