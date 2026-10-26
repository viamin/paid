# frozen_string_literal: true

# Links a feature intent to one issue in its tree (implementation issue or
# PR issue). An issue may serve several related designs; the verified receipt
# on each FeatureIntent records the distinct plan membership.
class FeatureIntentIssue < ApplicationRecord
  RELEASE_STATES = %w[held pending released reconciliation_failed].freeze
  PLANNING_TASK_KIND = "planning"
  PAID_HOLD_OWNER = "paid"

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
    persisted_mapping = prerequisite_mapping&.readiness_payload
    return readiness_mapping unless persisted_mapping

    persisted_mapping.deep_merge(readiness_mapping.slice("planning_hold"))
  end

  # A planning task creates the evidence that will authorize a later
  # implementation task. Its persisted contract is intentionally explicit:
  # only a Paid-owned, non-overridden receipt may bypass the implementation
  # approval gate. Labels remain ordinary eligibility controls, so an operator
  # can independently hold the planning task.
  # @spec CONFIDENCE-DELIVERY-017
  def planning_task?
    planning_task_contract? && !operator_override?
  end

  # A generic GitHub label has no inherent ownership. Only the durable receipt
  # written by PublishHeldIssue authorizes ReleaseIssue to remove it. Receipts
  # predate the planning-hold JSON contract, so a matching implementation
  # publication also establishes ownership for an already-published link.
  # @spec CONFIDENCE-DELIVERY-017
  def workflow_owned_planning_hold?
    return false if operator_override?

    return true if planning_hold.fetch("owner", nil) == PAID_HOLD_OWNER &&
      planning_hold.fetch("task_kind", nil) == "implementation"

    receipted_implementation_hold?
  end

  # The design revision a released link pins runs and reviews against.
  # ReleaseIssue snapshots carry the readiness design artifacts rather than a
  # dedicated merged_baseline key, so the first released artifact's revision
  # is the baseline, mirroring RunAdmission's admission pin.
  # @spec CONFIDENCE-DELIVERY-010
  def released_baseline_revision
    release_snapshot["merged_baseline"] || release_snapshot.dig("design_artifacts", 0, "revision")
  end

  private

  def planning_task_contract?
    planning_hold.fetch("owner", nil) == PAID_HOLD_OWNER &&
      planning_hold.fetch("task_kind", nil) == PLANNING_TASK_KIND
  end

  def planning_hold
    readiness_mapping.fetch("planning_hold", {}).to_h.deep_stringify_keys
  end

  # JSON contracts can arrive from persisted agent output, so normalize the
  # override flag instead of requiring an in-memory Ruby boolean. A string
  # "true" must retain the operator hold just like true does.
  def operator_override?
    ActiveModel::Type::Boolean.new.cast(planning_hold.fetch("operator_override", false)) == true
  end

  def receipted_implementation_hold?
    feature_intent.issue_publications.any? do |publication|
      publication.remote_issue_number == issue.github_number && publication.task_kind == "implementation"
    end
  end
end
