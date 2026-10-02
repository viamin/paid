# frozen_string_literal: true

# @spec FEATURE-APPROVAL-014
# An append-only snapshot of a human approval. The current approval columns on
# FeatureIntent are a read model; this relation preserves every revision.
class FeatureIntentApprovalRevision < ApplicationRecord
  belongs_to :feature_intent
  belongs_to :approved_by, class_name: "User"

  validates :approved_at, :source, :revision_number, presence: true
  validates :revision_number, uniqueness: { scope: :feature_intent_id }

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def prevent_mutation
    raise ActiveRecord::ReadOnlyRecord, "feature intent approval revisions are immutable"
  end
end
