# frozen_string_literal: true

# A preference is durable only after a person has supplied both its statement
# and scope. Interaction data and assessments deliberately have no write path
# to this record.
# @spec FACET-CONFIDENCE-007 QUESTION-EXPLORATION-011
class ExplicitPreference < ApplicationRecord
  include TenantScoped

  SCOPES = %w[user project feature].freeze

  belongs_to :user
  belongs_to :recorded_by, class_name: "User"
  belongs_to :project, optional: true
  belongs_to :feature_intent, optional: true
  belongs_to :chat_session, optional: true

  validates :scope, inclusion: { in: SCOPES }
  validates :statement, presence: true
  validate :scope_target_present
  validate :targets_belong_to_account

  scope :for_owner, ->(user) { where(user:) }
  scope :for_project, ->(project) { where(project:) }

  private

  def scope_target_present
    validate_user_scope if scope == "user"
    validate_project_scope if scope == "project"
    validate_feature_scope if scope == "feature"
  end

  def validate_user_scope
    errors.add(:project, "must be blank for user scope") if project.present?
    errors.add(:feature_intent, "must be blank for user scope") if feature_intent.present?
  end

  def validate_project_scope
    errors.add(:project, "must be present for project scope") if project.blank?
    errors.add(:feature_intent, "must be blank for project scope") if feature_intent.present?
  end

  def validate_feature_scope
    errors.add(:feature_intent, "must be present for feature scope") if feature_intent.blank?
    errors.add(:project, "must match the feature intent's project") if feature_intent.present? && project != feature_intent.project
  end

  def targets_belong_to_account
    validate_account(project, :project)
    validate_account(feature_intent&.project, :feature_intent)
    validate_account(chat_session, :chat_session)
    validate_account(user, :user)
    validate_account(recorded_by, :recorded_by)
  end

  def validate_account(record, attribute)
    return if record.blank? || record.account_id == account_id

    errors.add(attribute, "must belong to the preference account")
  end
end
