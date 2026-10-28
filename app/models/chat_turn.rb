# frozen_string_literal: true

class ChatTurn < ApplicationRecord
  STATES = %w[pending streaming completed failed stalled abandoned].freeze
  STALL_THRESHOLD = 10.minutes

  belongs_to :chat_session
  belongs_to :user_message, class_name: "ChatMessage"
  has_many :messages, class_name: "ChatMessage", dependent: :nullify

  validates :state, inclusion: { in: STATES }
  validates :activity_at, presence: true

  scope :detectable, -> { where(state: "streaming") }

  class << self
    def current
      Thread.current[:paid_chat_turn]
    end

    def with_current(chat_turn)
      previous = current
      Thread.current[:paid_chat_turn] = chat_turn
      yield
    ensure
      Thread.current[:paid_chat_turn] = previous
    end
  end

  def start!
    transition!("streaming")
  end

  def complete!
    transition!("completed", completed_at: Time.current)
  end

  def await_confirmation!
    transition!("pending", metadata: metadata.merge("wait_reason" => "tool_confirmation"))
  end

  def fail!(classification:)
    transition!("failed", completed_at: Time.current, failure_classification: classification)
  end

  def stalled!
    transition!("stalled", stalled_at: Time.current)
  end

  def record_activity!
    update!(activity_at: Time.current) unless state.in?(%w[completed failed stalled abandoned])
  end

  def pending_confirmation?
    state == "pending" && metadata["wait_reason"] == "tool_confirmation"
  end

  # Conservative by design: a turn that has persisted any tool result must be
  # reviewed instead of replayed. This first slice only resumes turns with no
  # possible tool side effect.
  def safely_resumable?
    state == "stalled" && !messages.where(role: "tool").exists?
  end

  private

  def transition!(next_state, **attributes)
    update!(**attributes.merge(state: next_state, activity_at: Time.current))
  end
end
