# frozen_string_literal: true

class IssueDependency < ApplicationRecord
  belongs_to :issue
  belongs_to :depends_on_issue, class_name: "Issue", optional: true

  validates :depends_on_issue_id, uniqueness: { scope: :issue_id }, if: :local?
  validates :depends_on_issue, presence: true, if: :local?
  validates :depends_on_owner, uniqueness: {
    scope: %i[issue_id depends_on_repo depends_on_number],
    case_sensitive: false
  }, if: :external?
  validates :depends_on_number, numericality: { only_integer: true, greater_than: 0 }, if: :external?
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

  # External deps whose target resolves to a tracked Issue in another
  # project of the given account, joined with that target row. Returns one
  # row per external dep, with `ext_project` and `ext_issue` available via
  # SQL aliases for downstream filtering. Targets outside the account
  # (project not synced into Paid) appear with NULL ext_project/ext_issue
  # since the join is a LEFT JOIN — callers decide how to treat the
  # unresolved case.
  #
  # Owner/repo are compared case-insensitively because
  # IssueDependency#normalize_external_ref downcases the dep side on
  # write, while Project.owner/name preserve their original casing.
  EXTERNAL_RESOLUTION_JOIN_SQL = <<~SQL.squish.freeze
    LEFT JOIN projects ext_project
      ON ext_project.account_id = ? AND
         LOWER(ext_project.owner) = issue_dependencies.depends_on_owner AND
         LOWER(ext_project.name) = issue_dependencies.depends_on_repo
    LEFT JOIN issues ext_issue
      ON ext_issue.project_id = ext_project.id AND
         ext_issue.github_number = issue_dependencies.depends_on_number
  SQL

  scope :external_resolved_for_account, ->(account_id) {
    where.not(depends_on_owner: nil)
      .joins(sanitize_sql_array([ EXTERNAL_RESOLUTION_JOIN_SQL, account_id ]))
  }

  # External deps that should still block their dependent: target project
  # not synced into the account, target issue not yet synced, or target
  # is observably open (and not in a local state treated as effectively
  # resolved for downstream scheduling).
  scope :still_blocking_external_for_account, ->(account_id) {
    external_resolved_for_account(account_id)
      .where(
        "ext_project.id IS NULL OR ext_issue.id IS NULL OR " \
        "(ext_issue.github_state = 'open' AND ext_issue.paid_state NOT IN ('recommend_close', 'completed'))"
      )
  }

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

  # True when this dependency should remain blocking until the target PR
  # has been marked deployed (not merely merged). Only meaningful for
  # local deps that resolve to a PR; for external deps we cannot observe
  # deployment state, so requires_deployment has no incremental effect
  # beyond the existing always-blocking external behaviour.
  def deployment_pending?
    return false unless requires_deployment?
    return false unless local?

    target = depends_on_issue
    return false unless target&.is_pull_request?
    return false if target.github_state == "open" # already blocking via the regular path

    target.deployed_at.nil?
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
