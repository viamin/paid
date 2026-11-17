# frozen_string_literal: true

# A reviewed, immutable mapping revision. Replacements revoke the old row and
# append a new revision so later scheduling can never reinterpret old evidence.
# @spec STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-004
class StagedCloseoutMapping < ApplicationRecord
  STAGES = %w[pre_merge merged_revision live_environment].freeze
  STATUSES = %w[approved revoked superseded].freeze
  EXECUTION_PATHS = %w[technical_prerequisite trusted_measurement].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :staged_closeout_enrollment
  belongs_to :reviewed_by, class_name: "User"
  belongs_to :invalidated_by, class_name: "User", optional: true

  validates :criterion_key, :criterion_digest, :target_shape, :target_key, :target_version, :target_digest, presence: true
  validates :stage, inclusion: { in: STAGES }
  validates :status, inclusion: { in: STATUSES }
  validates :execution_path, inclusion: { in: EXECUTION_PATHS }
  validates :freshness_seconds, numericality: { only_integer: true, greater_than: 0 }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: [ :issue_id, :criterion_key ] }
  validate :account_matches_scope
  validate :reviewed_inputs_are_immutable, on: :update

  scope :approved, -> { where(status: "approved") }

  def current? = approved? && invalidated_at.nil?
  def approved? = status == "approved"

  private

  # @spec STAGED-CLOSEOUT-ADOPTION-007
  def reviewed_inputs_are_immutable
    mutable = %w[status invalidated_by_id invalidated_at invalidation_reason updated_at]
    (changes.keys - mutable).each { |field| errors.add(field, "is immutable; approve a replacement revision") }
  end

  def account_matches_scope
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
    errors.add(:issue, "must belong to the project") if issue && project && issue.project_id != project_id
    if staged_closeout_enrollment && project && staged_closeout_enrollment.project_id != project_id
      errors.add(:staged_closeout_enrollment, "must belong to the project")
    end
    errors.add(:reviewed_by, "must belong to the account") if reviewed_by && account && reviewed_by.account_id != account_id
    errors.add(:invalidated_by, "must belong to the account") if invalidated_by && account && invalidated_by.account_id != account_id
  end
end
