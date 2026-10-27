# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  # @spec CHAT-TURN-001
  STATUSES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :actor, class_name: "User"
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :stale_candidates, ->(threshold) { where(status: ACTIVE_STATUSES).where(last_activity_at: ...threshold) }

  def start!
    transition_to!("streaming", event_type: "started")
  end

  def record_activity!(event_type: "activity")
    return if terminal?

    update!(last_activity_at: Time.current)
    events.create!(event_type: event_type)
  end

  def await_confirmation!
    transition_to!("awaiting_confirmation", event_type: "awaiting_confirmation")
  end

  def complete!
    transition_to!("completed", event_type: "completed", terminal: true)
  end

  def fail!(classification:)
    transition_to!("failed", event_type: "failed", terminal: true, failure_classification: classification)
  end

  def stall!
    transition_to!("stalled", event_type: "stalled", terminal: true, stalled_at: Time.current,
      failure_classification: "inactivity")
  end

  def terminal?
    status.in?(%w[completed failed stalled abandoned])
  end

  private

  def transition_to!(new_status, event_type:, terminal: false, **attributes)
    with_lock do
      return false if terminal?

      now = Time.current
      update!(status: new_status, last_activity_at: now, terminal_at: (now if terminal), **attributes)
      events.create!(event_type: event_type, metadata: attributes.stringify_keys)
    end
  end
end
