# frozen_string_literal: true

# @spec CHAT-TURN-RECOVERY-001 CHAT-TURN-RECOVERY-002
class ChatTurn < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :account
  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :inactive_before, ->(time) { unfinished.where(last_activity_at: ...time) }

  def record_activity!(side_effecting_tool_completed: false)
    attributes = { status: "streaming", last_activity_at: Time.current }
    attributes[:side_effecting_tools_completed] = true if side_effecting_tool_completed
    update!(attributes)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
    record_event!("completed")
  end

  def fail!(classification:)
    update!(status: "failed", failed_at: Time.current, last_activity_at: Time.current, failure_classification: classification)
    record_event!("failed", classification: classification)
  end

  def stall!(detected_at: Time.current)
    update!(status: "stalled", stalled_at: detected_at)
    record_event!("stalled", side_effecting_tools_completed: side_effecting_tools_completed)
  end

  def record_event!(event_type, **metadata)
    events.create!(account: account, event_type: event_type, occurred_at: Time.current, metadata: metadata)
  end
end
