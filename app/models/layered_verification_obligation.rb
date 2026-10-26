# frozen_string_literal: true

class LayeredVerificationObligation < ApplicationRecord
  # @spec LAYERED-VERIFY-004
  # @spec LAYERED-VERIFY-006
  FRAMEWORKS = %w[lid okf paid_offered_cir unresolved].freeze
  APPROVAL_STATES = %w[proposed approved unresolved].freeze

  class ApprovalNotPersistedError < StandardError; end

  belongs_to :project
  belongs_to :superseded_by, class_name: "LayeredVerificationObligation", optional: true
  belongs_to :change_intent, optional: true

  has_many :supersedes, class_name: "LayeredVerificationObligation", foreign_key: :superseded_by_id,
    inverse_of: :superseded_by, dependent: :nullify
  has_many :correspondence_claims, class_name: "LayeredVerificationCorrespondenceClaim",
    foreign_key: :obligation_id, dependent: :destroy, inverse_of: :obligation
  has_many :check_results, class_name: "LayeredVerificationCheckResult",
    foreign_key: :obligation_id, dependent: :restrict_with_exception, inverse_of: :obligation
  has_many :findings, class_name: "LayeredVerificationFinding", foreign_key: :obligation_id, dependent: :restrict_with_exception

  validates :framework, inclusion: { in: FRAMEWORKS }
  validates :external_identity, :scope_description, presence: true
  validates :approval_state, inclusion: { in: APPROVAL_STATES }
  validates :external_identity, uniqueness: { scope: [ :project_id, :framework, :external_identity ] }
  validate :change_intent_belongs_to_project
  validate :superseded_by_belongs_to_same_project, if: -> { superseded_by.present? }
  validate :superseded_by_is_not_self
  validate :approved_state_has_repository_reference
  validate :approved_transition_is_persisted

  def record_approval!(revision:, approval_reference:, persisted:)
    raise ApprovalNotPersistedError, "approval is not persisted in the target repository" unless persisted

    with_lock do
      with_persisted_approval do
        update!(
          approval_state: "approved",
          external_revision: revision,
          approved_revision_reference: approval_reference,
          synced_at: Time.current
        )
      end
    end
  end

  private

  def with_persisted_approval
    @persisting_approval = true
    yield
  ensure
    @persisting_approval = false
  end

  def approved_state_has_repository_reference
    return unless approval_state == "approved"
    return if external_revision.present? && approved_revision_reference.present?

    errors.add(:approval_state, "requires a persisted repository revision and reference")
  end

  def approved_transition_is_persisted
    return unless will_save_change_to_approval_state? && approval_state == "approved"
    return if @persisting_approval

    errors.add(:approval_state, "can only be approved through record_approval!")
  end

  def change_intent_belongs_to_project
    return unless change_intent && change_intent.project_id != project_id

    errors.add(:change_intent, "must belong to the same project")
  end

  def superseded_by_belongs_to_same_project
    return if superseded_by.project_id == project_id

    errors.add(:superseded_by, "must belong to the same project")
  end

  def superseded_by_is_not_self
    return unless persisted? && superseded_by_id == id

    errors.add(:superseded_by, "cannot reference itself")
  end
end
