# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  DEFAULT_STALL_THRESHOLD = 5.minutes

  belongs_to :chat_session
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :last_activity_at, presence: true

  scope :stale_streaming, ->(cutoff) { where(status: "streaming", last_activity_at: ..cutoff) }

  def self.stall_threshold
    Integer(ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", DEFAULT_STALL_THRESHOLD.to_i)).seconds
  rescue ArgumentError
    DEFAULT_STALL_THRESHOLD
  end

  def mark_streaming!
    update!(status: "streaming", last_activity_at: Time.current, failure_classification: nil)
  end

  def mark_pending!(classification: nil)
    update!(status: "pending", last_activity_at: Time.current, failure_classification: classification)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
  end

  def record_activity!
    update!(last_activity_at: Time.current) if status.in?(%w[pending streaming])
  end

  # @spec CHAT-TURN-RECOVERY-002
  def stall_if_eligible!(cutoff:)
    with_lock do
      reload
      return false unless status == "streaming" && last_activity_at <= cutoff
      return false if chat_session.rate_limited? || messages.pending_tool_confirmations.exists?

      update!(status: "stalled", stalled_at: Time.current)
      messages.create!(chat_session:, role: "system", content: stalled_notice_content, metadata: stalled_notice_metadata)
      true
    end
  end

  private

  def stalled_notice_content
    completed = messages.where(role: "tool").count
    "This turn stopped before a final response was recorded. #{completed} tool result#{'s' unless completed == 1} " \
      "were preserved, but anything after the last recorded activity is unknown. Send a new message to resume safely; " \
      "no tool calls were replayed automatically."
  end

  def stalled_notice_metadata
    { "stalled_turn_notice" => true, "chat_turn_id" => id, "stalled_at" => stalled_at.iso8601,
      "completed_tool_results" => messages.where(role: "tool").count }
  end
end
