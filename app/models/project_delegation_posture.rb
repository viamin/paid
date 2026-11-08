# frozen_string_literal: true

# The durable project delegation posture (RDR-080): one row per project
# recording the selected level, the authorized selector, the monotonic
# revision, the policy signature current at selection, and the enabled action
# classes. It is delegation consent only — never execution authority, which
# stays with the RDR-077 phase policy and RDR-078 bounded authorization.
#
# @spec PROJECT-DELEGATION-001
class ProjectDelegationPosture < ApplicationRecord
  belongs_to :account
  belongs_to :project
  belongs_to :selected_by, class_name: "User", optional: true, inverse_of: :selected_delegation_postures

  validates :project, uniqueness: { message: "has already been configured" }
  validates :level, presence: true, inclusion: {
    in: ProjectDelegation::Posture::LEVELS, message: "is not a supported delegation posture"
  }
  validates :revision, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :policy_signature, presence: true
  validate :enabled_action_classes_are_delegable
  validate :account_matches_project
  validate :selector_belongs_to_account

  private

  def enabled_action_classes_are_delegable
    return errors.add(:enabled_action_classes, "must be an array") unless enabled_action_classes.is_a?(Array)

    classes = enabled_action_classes.map(&:to_s)
    if classes.any? { |action_class| ProjectDelegation::Posture::DELEGATED_ACTION_CLASSES.exclude?(action_class) }
      errors.add(:enabled_action_classes, "contains action classes #{level} does not delegate")
    end

    if level == ProjectDelegation::Posture::CONSERVATIVE && classes.any?
      errors.add(:enabled_action_classes, "conservative delegates no action classes")
    end
  end

  def account_matches_project
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
  end

  def selector_belongs_to_account
    errors.add(:selected_by, "must belong to the account") if selected_by && account && selected_by.account_id != account_id
  end
end
