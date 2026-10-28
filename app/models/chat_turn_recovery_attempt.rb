# frozen_string_literal: true

class ChatTurnRecoveryAttempt < ApplicationRecord
  include TenantScoped

  STATUSES = %w[queued running completed failed].freeze

  belongs_to :chat_turn
  belongs_to :requested_by, class_name: "User"

  validates :source_revision, uniqueness: { scope: :chat_turn_id }
  validates :status, inclusion: { in: STATUSES }
end
