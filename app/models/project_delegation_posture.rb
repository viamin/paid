# frozen_string_literal: true

# A project-scoped delegation posture (RDR-080): how far Paid may take
# downstream delivery after intent settles. It is posture only — execution
# authority stays with the RDR-077 phase policy and RDR-078 bounded
# authorizations. Every lifecycle write bumps the monotonic revision so
# admissions pinned to an earlier posture fail their next boundary recheck
# instead of silently following a broadened or narrowed setting.
#
# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
class ProjectDelegationPosture < ApplicationRecord
  LEVELS = %w[conservative bounded_delivery].freeze
  CONSERVATIVE = "conservative"
  DELEGATING_LEVEL = "bounded_delivery"

  belongs_to :account
  belongs_to :project
  belongs_to :selected_by, class_name: "User", optional: true
  belongs_to :held_by, class_name: "User", optional: true

  validates :project, uniqueness: true
  validates :level, presence: true, inclusion: { in: LEVELS, message: "is not a supported delegation posture" }
  validates :revision, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validate :account_matches_scope
  validate :selector_belongs_to_account
  validate :holder_belongs_to_account

  before_update :bump_revision

  def held?
    held_at.present?
  end

  def delegating?
    level == DELEGATING_LEVEL && !held?
  end

  # Lifecycle write only: surfaces reach selection through
  # ProjectDelegation::Posture, which enforces the actor policy. Selection is
  # broadening or narrowing alike — the revision bump is what keeps
  # in-flight admissions pinned to the posture they were admitted under.
  def select!(level:, user:)
    with_lock do
      update!(
        level: level.to_s,
        selected_by: user,
        selected_at: Time.current,
        enabled_action_classes: self.class.action_classes_for(level),
        policy_signature: self.class.policy_signature_for(project)
      )
      Audit::RecordEvent.call(
        action: "project_delegation.selected",
        actor: user,
        subject: self,
        metadata: { "level" => level.to_s, "revision" => revision, "enabled_action_classes" => enabled_action_classes }
      )
    end
    self
  end

  # An explicit hold is the reversible narrowing: delegated boundaries block
  # while the recorded level stays untouched, and the audit trail keeps the
  # hold and its release.
  def hold!(user:, reason: nil)
    with_lock do
      return self if held?

      update!(held_at: Time.current, held_by: user, hold_reason: reason)
      Audit::RecordEvent.call(
        action: "project_delegation.held",
        actor: user,
        subject: self,
        metadata: { "reason" => reason, "revision" => revision }
      )
    end
    self
  end

  def release_hold!(user:)
    with_lock do
      return self unless held?

      update!(held_at: nil, held_by: nil, hold_reason: nil)
      Audit::RecordEvent.call(
        action: "project_delegation.hold_released",
        actor: user,
        subject: self,
        metadata: { "revision" => revision }
      )
    end
    self
  end

  # Conservative rollback (RDR-080): reaching this write through
  # ProjectDelegation::Rollback additionally routes focused recovery
  # decisions for in-flight delegated work. The record itself only narrows.
  def rollback!(user:, reason: nil)
    with_lock do
      from_level = level
      update!(
        level: CONSERVATIVE,
        selected_by: user,
        selected_at: Time.current,
        enabled_action_classes: self.class.action_classes_for(CONSERVATIVE)
      )
      Audit::RecordEvent.call(
        action: "project_delegation.rolled_back",
        actor: user,
        subject: self,
        metadata: { "reason" => reason, "from_level" => from_level, "revision" => revision }
      )
    end
    self
  end

  # Digest of the project phase-policy settings current at selection time, so
  # the stored posture names the policy it was selected against.
  def self.policy_signature_for(project)
    Digest::SHA256.hexdigest(Automation::PhaseSettings.call(project).to_h.to_json)
  end

  # The action classes a posture level delegates. Conservative delegates
  # nothing; bounded delivery delegates the RDR-078 bounded action classes.
  def self.action_classes_for(level)
    level.to_s == DELEGATING_LEVEL ? BoundedDelegatedAction::ACTIONS : []
  end

  private

  def bump_revision
    self.revision = revision + 1 unless will_save_change_to_revision?
  end

  def account_matches_scope
    errors.add(:account, "must match the project") if account && project && account_id != project.account_id
  end

  def selector_belongs_to_account
    errors.add(:selected_by, "must belong to the account") if selected_by && account && selected_by.account_id != account_id
  end

  def holder_belongs_to_account
    errors.add(:held_by, "must belong to the account") if held_by && account && held_by.account_id != account_id
  end
end
