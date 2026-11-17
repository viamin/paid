# frozen_string_literal: true

module ProjectDelegation
  # @spec PROJECT-DELEGATION-002
  class IntentCheckpoint < ApplicationRecord
    self.table_name = "project_delegation_intent_checkpoints"
    STATUSES = %w[open settled rejected amended].freeze

    belongs_to :feature_intent
    has_many :questions, class_name: "FeatureIntentDecision", foreign_key: :intent_checkpoint_id,
      inverse_of: :intent_checkpoint, dependent: :nullify
    has_many :settlements, class_name: "ProjectDelegation::IntentSettlement", dependent: :restrict_with_error

    validates :status, inclusion: { in: STATUSES }
    validates :recommendation, presence: true
    validates :proposed_design_revision, :proposed_acceptance_revision, presence: true, on: :settlement

    def settled? = status == "settled"

    def current_binding?(design_revision:, acceptance_revision:)
      settlement = settlements.order(created_at: :desc).first
      settlement.present? && settlement.design_revision == design_revision && settlement.acceptance_revision == acceptance_revision
    end
  end
end
