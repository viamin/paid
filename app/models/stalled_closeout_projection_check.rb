# frozen_string_literal: true

# One checkpoint per project for the persisted partial-closeout stall
# projection (RDR-081 Option B, #4912). A row with non-null `computed_at`
# records a successful recomputation — including one that found zero
# stalls — while `generation` identifies the atomic replacement its child
# rows belong to. A missing row, or null `computed_at`, means the project
# has not been evaluated successfully yet and its Inbox lane stays on the
# live path. `last_failure` keeps bounded metadata about the latest failed
# attempt without ever deleting the previous rows.
# @spec PARTIAL-CLOSEOUT-042
class StalledCloseoutProjectionCheck < ApplicationRecord
  belongs_to :project

  validates :generation, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  def evaluated?
    computed_at.present?
  end
end
