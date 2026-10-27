# frozen_string_literal: true

# Durable lifecycle record for one user-initiated chat turn. Streaming events
# are deliberately not the source of truth: a worker restart or disconnected
# browser must not turn an unfinished turn into an apparent success.
class ChatTurn < ApplicationRecord
  include TenantScoped
  STATUSES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_TIMEOUT = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true
  belongs_to :actor, class_name: "User", optional: true
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :status, inclusion: { in: STATUSES }
  validates :stream_message_id, presence: true, uniqueness: { scope: :chat_session_id }
  validates :last_activity_at, presence: true

  scope :unfinished, -> { where(status: %w[pending streaming]) }
  scope :stale_before, ->(time) { unfinished.where(last_activity_at: ...time) }

  def pending_confirmation?
    messages.pending_tool_confirmations.exists?
  end

  def rate_limited?
    chat_session.rate_limited?
  end

  def touch_activity!(message: nil)
    update!(last_activity_at: Time.current, status: "streaming") if pending? || streaming?
    update_side_effecting_tools! if side_effecting_tool_result?(message)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, last_activity_at: Time.current)
  end

  def fail!(classification:)
    update!(status: "failed", failed_at: Time.current, metadata: metadata.merge("failure_classification" => classification))
  end

  def stall!(classification: "no_durable_activity")
    update!(status: "stalled", stalled_at: Time.current, stall_classification: classification)
  end

  private

  def update_side_effecting_tools!
    return if side_effecting_tools_completed?

    update!(side_effecting_tools_completed: true)
  end

  def side_effecting_tool_result?(message)
    message&.role == "tool" && Tools::Registry.write_tool?(message.tool_name)
  end
end
