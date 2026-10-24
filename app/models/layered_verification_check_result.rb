# frozen_string_literal: true

class LayeredVerificationCheckResult < ApplicationRecord
  # @spec LAYERED-VERIFY-008
  PRODUCERS = %w[
    business_formalization verification_planning engineering_translation linkage_freshness
    behavioral_testing formal_verification mutation_testing implementation_conformance semantic_audit
  ].freeze
  EXECUTION_STATES = %w[completed failed_assertion execution_error incomplete not_run non_applicable stale].freeze
  OBLIGATION_COVERAGES = %w[supported contradicted unresolved].freeze

  class ImmutableResultError < StandardError; end

  belongs_to :obligation, class_name: "LayeredVerificationObligation", inverse_of: :check_results
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true,
    inverse_of: :check_results
  belongs_to :agent_run, optional: true

  before_update :prevent_mutation!
  before_destroy :prevent_mutation!

  validates :producer, inclusion: { in: PRODUCERS }
  validates :execution_state, inclusion: { in: EXECUTION_STATES }
  validates :obligation_coverage, inclusion: { in: OBLIGATION_COVERAGES }
  validates :limitations, presence: true
  validate :correspondence_claim_belongs_to_obligation, if: -> { correspondence_claim.present? }
  validate :agent_run_belongs_to_same_project, if: -> { agent_run.present? }

  private

  def correspondence_claim_belongs_to_obligation
    return if correspondence_claim.obligation_id == obligation_id

    errors.add(:correspondence_claim, "must belong to the same obligation")
  end

  def agent_run_belongs_to_same_project
    return if agent_run.project_id == obligation.project_id

    errors.add(:agent_run, "must belong to the same project")
  end

  def prevent_mutation!
    raise ImmutableResultError, "check results are append-only"
  end
end
