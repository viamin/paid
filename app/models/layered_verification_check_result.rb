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

  private

  def prevent_mutation!
    raise ImmutableResultError, "check results are append-only"
  end
end
