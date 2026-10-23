# frozen_string_literal: true

# RDR-077 §5: personal removal of an Inbox request for one user.
#
# Removal is presentation-only: the request, its questions, its history, and
# its automation authorization are untouched, and other users are unaffected.
# The stored occurrence is what makes the suppression durable — a fresh
# occurrence (or a phase re-enablement) makes the request eligible again.
#
# @spec INBOX-PHASE-RELEVANCE-006 @spec INBOX-PHASE-RELEVANCE-008
class InboxRemoval < ApplicationRecord
  belongs_to :user
  belongs_to :project, optional: true

  validates :request_key, presence: true
  validates :entry_kind, presence: true
  validates :request_occurrence, presence: true
  validates :removed_at, presence: true
  validates :request_key, uniqueness: { scope: %i[user_id request_occurrence] }

  scope :active, -> { where(cleared_at: nil) }
  scope :cleared, -> { where.not(cleared_at: nil) }
  scope :for_phases, ->(phases) { where(responsible_phase: Array(phases).map(&:to_s)) }

  def active?
    cleared_at.nil?
  end

  # A stored removal suppresses the request while the request's current
  # occurrence is not newer than the removed occurrence.
  def suppresses?(current_occurrence)
    return false unless active?

    (current_occurrence.to_s <=> request_occurrence.to_s) <= 0
  end

  def clear!
    return false unless active?

    update!(cleared_at: Time.current)
  end
end