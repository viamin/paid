# frozen_string_literal: true

class ChatTurnRecoveryAttempt < ApplicationRecord
  STATUSES = %w[queued running completed failed].freeze

  belongs_to :chat_turn, counter_cache: :recovery_attempts_count
  belongs_to :actor, class_name: "User"

  validates :status, inclusion: { in: STATUSES }
  validates :requested_revision, uniqueness: { scope: :chat_turn_id }
end
