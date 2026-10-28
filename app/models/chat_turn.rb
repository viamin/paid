# frozen_string_literal: true

# @spec CHAT-TURN-001 CHAT-TURN-002
class ChatTurn < ApplicationRecord
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = ENV.fetch("CHAT_TURN_STALL_THRESHOLD_SECONDS", 10.minutes).to_i.seconds

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { unfinished.where(last_activity_at: ...time) }

  def self.find_or_start!(chat_session:, stream_message_id:)
    find_or_create_by!(chat_session:, stream_message_id:) do |turn|
      turn.status = "pending"
      turn.last_activity_at = Time.current
    end
  end

  def start!(user_message:)
    with_lock do
      update!(status: "streaming", user_message:, last_activity_at: Time.current)
    end
  end

  def touch_activity!
    update!(last_activity_at: Time.current) if status.in?(%w[pending streaming])
  end

  def complete!
    with_lock { update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current) }
  end

  def fail!(classification:)
    with_lock do
      return unless status.in?(%w[pending streaming])

      update!(status: "failed", failure_classification: classification, last_activity_at: Time.current)
    end
  end

  def pending_confirmation?
    chat_session.messages.pending_tool_confirmations.where("id > ?", user_message_id || 0).exists?
  end

  def rate_limited?
    chat_session.rate_limited?
  end

  def eligible_to_stall?(now: Time.current)
    status.in?(%w[pending streaming]) && last_activity_at < now - STALL_THRESHOLD && !pending_confirmation? && !rate_limited?
  end

  def mark_stalled!
    with_lock do
      reload
      return false unless eligible_to_stall?

      update!(status: "stalled", stalled_at: Time.current)
      create_stall_notice!
      true
    end
  end

  def begin_recovery!
    with_lock do
      raise ArgumentError, "Turn is not stalled" unless status == "stalled"
      raise ArgumentError, "Recovery requires confirmation because tools may have completed" if side_effecting_tools_completed
      raise ArgumentError, "Recovery is already in progress" if recovery_started_at.present?

      update!(status: "streaming", recovery_started_at: Time.current, recovery_count: recovery_count + 1, last_activity_at: Time.current)
    end
  end

  def note_side_effecting_tool!
    update!(side_effecting_tools_completed: true, last_activity_at: Time.current)
  end

  private

  def create_stall_notice!
    return if chat_session.messages.system.where("metadata ->> 'chat_turn_stalled_notice' = ?", "true").where("metadata ->> 'chat_turn_id' = ?", id.to_s).exists?

    chat_session.messages.create!(
      role: "system",
      content: "This turn stopped before a final response was saved. Completed tool activity is preserved; anything after the last recorded activity is unknown. Review the transcript before retrying.",
      metadata: { "chat_turn_stalled_notice" => true, "chat_turn_id" => id, "side_effecting_tools_completed" => side_effecting_tools_completed }
    )
  end
end
