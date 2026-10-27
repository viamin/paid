# frozen_string_literal: true

# Durable lifecycle for one user-initiated chat turn. Browser streaming is
# intentionally not evidence of completion: only persisted transcript state
# advances this record to a terminal state.
class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming awaiting_confirmation completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :state, inclusion: { in: STATES }
  validates :user_message_id, uniqueness: true

  scope :detectable_stalls, ->(now = Time.current) {
    where(state: %w[pending streaming]).where(last_activity_at: ...(now - STALL_TIMEOUT))
  }

  def mark_streaming!
    transition!("streaming")
  end

  def mark_awaiting_confirmation!
    transition!("awaiting_confirmation")
  end

  def mark_completed!
    transition!("completed", completed_at: Time.current)
  end

  def mark_failed!(classification:)
    transition!("failed", metadata: metadata.merge("failure_classification" => classification))
  end

  def touch_activity!
    update_columns(last_activity_at: Time.current, updated_at: Time.current) unless completed? || failed? || stalled?
  end

  def completed?
    state == "completed"
  end

  def failed?
    state == "failed"
  end

  def stalled?
    state == "stalled"
  end

  def safe_to_replay?
    chat_session.messages.where("id > ?", user_message_id).where(role: "tool").none?
  end

  private

  def transition!(next_state, attributes = {})
    update!(attributes.merge(state: next_state, last_activity_at: Time.current))
  end
end
