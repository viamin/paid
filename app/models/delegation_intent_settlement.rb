# frozen_string_literal: true

# The immutable human settlement of one intent checkpoint: the disposition
# (settled, rejected, or amended), the per-group answers or amendments, the
# actor, the time, and the design and acceptance revisions the answers bind.
# Append-only at the database layer, exactly like the RDR-066 approval
# revisions it complements; a changed mind or a changed revision opens a new
# checkpoint cycle rather than editing history.
# @spec PROJECT-DELEGATION-002
class DelegationIntentSettlement < ApplicationRecord
  DISPOSITIONS = %w[settled rejected amended].freeze

  belongs_to :delegation_intent_checkpoint
  belongs_to :settled_by, class_name: "User"

  validates :disposition, presence: true, inclusion: { in: DISPOSITIONS }
  validates :design_revision, :acceptance_revision, :settled_at, presence: true
  validate :answers_shape
  validate :settled_by_belongs_to_account

  def checkpoint
    delegation_intent_checkpoint
  end

  def settled? = disposition == "settled"
  def rejected? = disposition == "rejected"
  def amended? = disposition == "amended"

  def answer_for(group_key)
    entries = answers.is_a?(Array) ? answers : []
    entry = entries.find { |candidate| candidate.is_a?(Hash) && candidate["group_key"].to_s == group_key.to_s }
    entry && entry["answer"].presence
  end

  private

  def answers_shape
    return errors.add(:answers, "must be a list") unless answers.is_a?(Array)

    answers.each do |entry|
      valid = entry.is_a?(Hash) && entry["group_key"].to_s.present? &&
              (entry["answer"].to_s.present? || entry["amendment"].to_s.present?)
      errors.add(:answers, "each entry needs a group_key and an answer or amendment") unless valid
    end
  end

  def settled_by_belongs_to_account
    account = checkpoint&.account
    errors.add(:settled_by, "must belong to the checkpoint account") if settled_by && account && settled_by.account_id != account.id
  end
end
