# frozen_string_literal: true

# Durable lifecycle for one user-initiated chat turn. A terminal response is
# never inferred from transport completion alone.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 15.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, uniqueness: true, allow_nil: true

  scope :incomplete, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { incomplete.where(last_activity_at: ...time) }

  def touch_activity!(event_type, metadata = {})
    update!(last_activity_at: Time.current)
    events.create!(event_type:, metadata:)
  end

  def start!
    update!(status: "streaming", last_activity_at: Time.current)
    events.create!(event_type: "started")
  end

  def complete!(outcome: "assistant_response")
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    events.create!(event_type: "completed", metadata: { "outcome" => outcome })
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, completed_at: Time.current, last_activity_at: Time.current)
    events.create!(event_type: "failed", metadata: { "classification" => classification })
  end

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("created_at >= ?", user_message.created_at).exists?
  end
end
