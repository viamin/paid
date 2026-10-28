# frozen_string_literal: true

# A durable outcome record for one user-originated chat turn. The transcript
# remains the evidence; this row makes an incomplete turn queryable without
# treating a missing assistant response as success.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming waiting_for_confirmation completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stalled, -> { where(status: "stalled") }
  scope :overdue, ->(now = Time.current) { active.where(last_activity_at: ..(now - stall_threshold)) }

  class << self
    def stall_threshold
      seconds = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", STALL_THRESHOLD.to_i).to_i
      seconds.positive? ? seconds.seconds : STALL_THRESHOLD
    end
  end

  def record_activity!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def wait_for_confirmation!
    update!(status: "waiting_for_confirmation", last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, completed_at: Time.current, last_activity_at: Time.current)
  end

  def side_effecting_tools_completed?
    chat_session.messages.where("chat_messages.id > ?", user_message_id).where(role: "tool").exists?
  end
end
