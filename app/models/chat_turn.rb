# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  RECOVERY_STATES = %w[none in_progress succeeded failed].freeze
  OPEN_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  has_many :events, class_name: "ChatTurnEvent", dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :recovery_state, inclusion: { in: RECOVERY_STATES }

  scope :open, -> { where(status: OPEN_STATUSES) }

  def awaiting_confirmation?
    metadata.is_a?(Hash) && metadata["awaiting_confirmation"] == true
  end

  def side_effecting_tools_completed?
    metadata.is_a?(Hash) && metadata["side_effecting_tools_completed"] == true
  end

  def record_activity!(message)
    completed_tools = Array(metadata["completed_tools"])
    completed_tools << message.tool_name if message.role == "tool" && message.tool_name.present?
    details = metadata.merge("completed_tools" => completed_tools.uniq, "awaiting_confirmation" => message.pending_confirmation?)
    details["side_effecting_tools_completed"] = true if message.role == "tool" && Tools::Registry.write_tool?(message.tool_name)
    update!(status: "streaming", last_activity_at: Time.current, metadata: details, revision: revision + 1)
  end

  def complete!
    return unless status.in?(OPEN_STATUSES)

    update!(status: "completed", finished_at: Time.current, last_activity_at: Time.current, revision: revision + 1)
  end

  def fail!(classification)
    return unless status.in?(OPEN_STATUSES)

    update!(status: "failed", failure_classification: classification, finished_at: Time.current, revision: revision + 1)
  end

  def mark_stalled!(classification)
    return false unless status.in?(OPEN_STATUSES)

    update!(status: "stalled", failure_classification: classification, stalled_at: Time.current, finished_at: Time.current, revision: revision + 1)
    true
  end

  def abandon!
    update!(status: "abandoned", abandoned_at: Time.current, finished_at: Time.current, revision: revision + 1)
  end
end
