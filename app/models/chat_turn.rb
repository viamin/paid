# frozen_string_literal: true

# Durable lifecycle record for one user-initiated chat turn. It deliberately
# records an interrupted turn as non-terminal until the stall detector can
# explain it; no transcript row is fabricated as a successful assistant reply.
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming waiting_confirmation completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :initiating_message, class_name: "ChatMessage"
  belongs_to :actor, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :initiating_message_id, uniqueness: true

  scope :eligible_for_stall_detection, ->(before) { where(status: %w[pending streaming]).where(last_activity_at: ..before) }
  scope :stalled, -> { where(status: "stalled") }

  def touch_activity!
    update!(last_activity_at: Time.current) unless completed? || failed? || stalled? || abandoned?
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def wait_for_confirmation!
    update!(status: "waiting_confirmation", last_activity_at: Time.current)
  end

  def failed!(classification)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end

  def stalled!
    update!(status: "stalled", detected_stalled_at: Time.current)
  end

  def completed? = status == "completed"
  def failed? = status == "failed"
  def stalled? = status == "stalled"
  def abandoned? = status == "abandoned"
end
