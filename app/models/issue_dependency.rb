# frozen_string_literal: true

class IssueDependency < ApplicationRecord
  belongs_to :issue
  belongs_to :depends_on_issue, class_name: "Issue", optional: true

  validates :depends_on_issue_id, uniqueness: { scope: :issue_id }, if: :local?
  validates :depends_on_owner, uniqueness: {
    scope: %i[issue_id depends_on_repo depends_on_number],
    case_sensitive: false
  }, if: :external?
  validate :not_self_referential
  validate :must_have_local_or_external_ref
  validate :local_and_external_mutually_exclusive
  validate :local_dep_within_same_account

  before_validation :normalize_external_ref

  # Builds an adjacency map { issue_id => [depends_on_issue_id, ...] }
  # for all local dependencies within a project. Used by ParseDependencies and
  # DetectCycle to avoid repeated full-table queries during batch syncs.
  def self.project_adjacency(project)
    where(issue_id: project.issues.select(:id))
      .where.not(depends_on_issue_id: nil)
      .pluck(:issue_id, :depends_on_issue_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  # Builds a global adjacency map across all local dependencies (all tenants).
  # Prefer account_adjacency for production use to avoid loading cross-tenant data.
  # Retained for testing and debugging purposes.
  def self.global_adjacency
    where.not(depends_on_issue_id: nil)
      .pluck(:issue_id, :depends_on_issue_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  # Builds an adjacency map scoped to an account's projects.
  # Preferred over global_adjacency to avoid loading cross-tenant data.
  def self.account_adjacency(account)
    joins(issue: :project)
      .where(projects: { account_id: account.id })
      .where.not(depends_on_issue_id: nil)
      .pluck(:issue_id, :depends_on_issue_id)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  def local?
    depends_on_issue_id.present? && depends_on_owner.blank?
  end

  def external?
    depends_on_issue_id.blank? &&
      depends_on_owner.present? && depends_on_repo.present? && depends_on_number.present?
  end

  def external_ref
    return unless external?

    "#{depends_on_owner}/#{depends_on_repo}##{depends_on_number}"
  end

  private

  def not_self_referential
    return unless issue_id && depends_on_issue_id
    return unless issue_id == depends_on_issue_id

    errors.add(:depends_on_issue, "cannot be the same as the issue")
  end

  def must_have_local_or_external_ref
    return if depends_on_issue_id.present?
    return if depends_on_owner.present? && depends_on_repo.present? && depends_on_number.present?

    errors.add(:base, "must reference a local issue or an external issue (owner/repo#number)")
  end

  def local_and_external_mutually_exclusive
    return unless depends_on_issue_id.present? &&
                  (depends_on_owner.present? || depends_on_repo.present? || depends_on_number.present?)

    errors.add(:base, "cannot reference both a local issue and an external issue")
  end

  def local_dep_within_same_account
    return unless depends_on_issue_id.present? && depends_on_issue.present?
    return unless issue&.project && depends_on_issue.project

    return if issue.project.account_id == depends_on_issue.project.account_id

    errors.add(:depends_on_issue, "must belong to the same account")
  end

  def normalize_external_ref
    self.depends_on_owner = depends_on_owner.presence&.downcase
    self.depends_on_repo = depends_on_repo.presence&.downcase
    self.depends_on_number = depends_on_number.presence if depends_on_number.is_a?(String)
  end
end
