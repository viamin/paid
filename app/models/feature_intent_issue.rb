# frozen_string_literal: true

# Links a feature intent to one issue in its tree (implementation issue or
# PR issue). An issue may serve several related designs; the verified receipt
# on each FeatureIntent records the distinct plan membership.
class FeatureIntentIssue < ApplicationRecord
  RELEASE_STATES = %w[held pending released reconciliation_failed].freeze

  belongs_to :feature_intent
  belongs_to :issue
  has_one :prerequisite_mapping, class_name: "FeatureIntentIssuePrerequisiteMapping", dependent: :destroy
  has_many :feature_intent_issue_dependencies, dependent: :destroy
  has_many :in_tree_dependencies, through: :feature_intent_issue_dependencies,
    source: :depends_on_feature_intent_issue
  has_many :reverse_feature_intent_issue_dependencies, class_name: "FeatureIntentIssueDependency",
    foreign_key: :depends_on_feature_intent_issue_id, dependent: :destroy, inverse_of: :depends_on_feature_intent_issue

  validates :issue_id, uniqueness: { scope: :feature_intent_id }
  validates :release_state, inclusion: { in: RELEASE_STATES }

  # The normalized prerequisite mapping is the current readiness producer.
  # Keep the JSON column as a compatibility fallback for links created before
  # prerequisite mappings were persisted.
  # @spec CONFIDENCE-DELIVERY-003
  def current_readiness_mapping
    prerequisite_mapping&.readiness_payload || readiness_mapping
  end

  # The design revision a released link pins runs and reviews against.
  # ReleaseIssue snapshots carry the readiness design artifacts rather than a
  # dedicated merged_baseline key, so the first released artifact's revision
  # is the baseline, mirroring RunAdmission's admission pin.
  # @spec CONFIDENCE-DELIVERY-010
  def released_baseline_revision
    release_snapshot["merged_baseline"] || release_snapshot.dig("design_artifacts", 0, "revision")
  end
end
