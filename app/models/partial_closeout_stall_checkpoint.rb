# frozen_string_literal: true

# Project-level checkpoint of the display-only partial-closeout stall
# projection (RDR-081). One row per project: `computed_at` stays null until
# the first successful recomputation commits, so an unevaluated project is
# distinguishable from an evaluated project with zero stalls. Failure metadata
# from the latest failed attempt is bounded and never advances the checkpoint
# or removes rows.
# @spec PARTIAL-CLOSEOUT-042
class PartialCloseoutStallCheckpoint < ApplicationRecord
  belongs_to :account
  belongs_to :project

  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # A successful checkpoint means "evaluated, possibly with zero stalls"; an
  # absent or never-successful checkpoint means "not evaluated successfully
  # yet" and keeps the project on the live lane path.
  def successful?
    computed_at.present?
  end
end
