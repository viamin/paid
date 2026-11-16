# frozen_string_literal: true

# RDR-081: the per-project checkpoint of the persisted stall read model. A
# row exists once its project is enrolled and first evaluated; `computed_at`
# is null until a recomputation succeeds, which is exactly the boundary the
# reader uses to keep an unevaluated project on the live admission path. The
# checkpoint records every successful recomputation — including an empty
# result — and bounded failure metadata from the latest failed attempt
# without ever deleting child rows or advancing the watermark on failure.
# @spec PARTIAL-CLOSEOUT-042
class StallProjectionCheckpoint < ApplicationRecord
  include TenantScoped

  belongs_to :project
  has_many :stalls, class_name: "StallProjectionStall", dependent: :delete_all

  validates :generation, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  def evaluated?
    computed_at.present?
  end
end
