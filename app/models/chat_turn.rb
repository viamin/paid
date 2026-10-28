# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  ACTIVE_STATUSES = %w[pending streaming].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"

  validates :status, inclusion: { in: STATUSES }
  validates :user_message_id, uniqueness: true

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :stale_before, ->(time) { active.where(last_activity_at: ...time) }

  def begin!
    update!(status: "streaming", last_activity_at: Time.current)
  end

  def touch_activity!
    update_column(:last_activity_at, Time.current)
  end

  def complete!(outcome: "assistant_response")
    update!(status: "completed", last_activity_at: Time.current, metadata: metadata.merge("outcome" => outcome))
  end

  def fail!(classification:)
    update!(status: "failed", last_activity_at: Time.current, metadata: metadata.merge("failure_classification" => classification))
  end

  def stall!
    with_lock do
      reload
      return false unless status.in?(ACTIVE_STATUSES)
      return false if chat_session.rate_limited? || pending_confirmation?

      update!(status: "stalled", detected_at: Time.current, metadata: metadata.merge("stall_classification" => "no_durable_activity"))
      true
    end
  end

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id > ?", user_message_id).exists?
  end
end
