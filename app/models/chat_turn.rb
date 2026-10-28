# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage", optional: true

  validates :state, inclusion: { in: STATES }

  scope :non_terminal, -> { where(state: %w[pending streaming]) }
  scope :inactive_before, ->(time) { non_terminal.where(last_activity_at: ...time) }

  def streaming?
    state == "streaming"
  end

  def stalled?
    state == "stalled"
  end

  def touch_activity!
    update!(last_activity_at: Time.current)
  end

  def complete!(outcome: nil)
    update!(state: "completed", terminal_at: Time.current, last_activity_at: Time.current,
      metadata: metadata.merge("outcome" => outcome).compact)
  end

  def fail!(classification:)
    update!(state: "failed", failure_classification: classification, terminal_at: Time.current, last_activity_at: Time.current)
  end

  def stall!
    update!(state: "stalled", detected_at: Time.current, terminal_at: Time.current, last_activity_at: Time.current,
      metadata: metadata.merge("side_effecting_tools_completed" => side_effecting_tools_completed?))
  end

  def side_effecting_tools_completed?
    chat_session.messages.where.not(tool_status: [nil, "pending"]).where.not(tool_name: nil).exists?
  end
end
