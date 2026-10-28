# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :state, inclusion: { in: STATES }

  scope :stall_candidates, ->(before) { where(state: "streaming").where(last_activity_at: ...before) }

  def stallable_at?(now, threshold:)
    streaming? && last_activity_at < now - threshold
  end

  def pending?
    state == "pending"
  end

  def streaming?
    state == "streaming"
  end

  def completed?
    state == "completed"
  end

  def stalled?
    state == "stalled"
  end

  def record!(event_type, metadata = {})
    events.create!(event_type:, metadata:)
  end
end
