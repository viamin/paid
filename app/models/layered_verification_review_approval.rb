# frozen_string_literal: true

class LayeredVerificationReviewApproval < ApplicationRecord
  # @spec LAYERED-VERIFY-023
  belongs_to :package, class_name: "LayeredVerificationReviewPackage", inverse_of: :approvals
  belongs_to :approved_by, class_name: "User"

  validates :approved_at, presence: true
  validates :provenance, presence: true

  before_update :prevent_mutation!
  before_destroy :prevent_mutation!

  private

  def prevent_mutation!
    # Approvals are append-only provenance; the owning package history keeps
    # them inspectable and revision-bound.
    raise LayeredVerificationReviewPackage::ImmutablePackageError, "review approvals are append-only"
  end
end
