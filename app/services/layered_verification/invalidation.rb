# frozen_string_literal: true

module LayeredVerification
  # Classifies append-only evidence for a later audit without changing the
  # outcome it originally recorded. A digest is an identity aid, not evidence
  # that all semantic dependencies were declared.
  # @spec LAYERED-VERIFY-019
  class Invalidation
    Impact = Data.define(:reusable_result_ids, :invalidated_result_ids, :limitations)

    def self.call(...) = new(...).call

    def initialize(obligations:, target_revision:, dependencies: {})
      @obligations = obligations
      @target_revision = target_revision.to_s
      @dependencies = dependencies.to_h.deep_stringify_keys
    end

    def call
      reusable, invalidated = results.partition { |result| reusable?(result) }
      Impact.new(reusable.map(&:id), invalidated.map(&:id), limitations(invalidated))
    end

    private

    attr_reader :dependencies, :obligations, :target_revision

    def results
      LayeredVerificationCheckResult.where(obligation: obligations).includes(:obligation).order(:id).to_a
    end

    def reusable?(result)
      revision = result.input_revision.to_h.deep_stringify_keys
      complete_dependency_basis?(revision) && revision["code"] == target_revision &&
        revision["external_revision"] == result.obligation.external_revision &&
        revision.fetch("dependencies") == dependencies
    end

    def complete_dependency_basis?(revision)
      revision["code"].present? && revision["external_revision"].present? &&
        revision["dependencies"].is_a?(Hash) && revision.fetch("dependencies").present?
    end

    def limitations(invalidated)
      return [] if invalidated.empty?

      [ "Evidence without a complete dependency basis was invalidated conservatively; content hashes alone do not establish dependency completeness." ]
    end
  end
end
