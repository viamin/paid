# frozen_string_literal: true

class InboxHistoryEvent < ApplicationRecord
  belongs_to :account
  belongs_to :project

  validates :subject_key, :event_key, :occurred_at, :actor_label, :source, :result, presence: true
  validates :event_key, uniqueness: { scope: %i[account_id subject_key] }

  scope :for_subject, ->(account:, subject_key:) { where(account:, subject_key:) }
  scope :newest_first, -> { order(occurred_at: :desc, id: :desc) }
end
