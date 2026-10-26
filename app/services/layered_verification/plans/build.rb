# frozen_string_literal: true

module LayeredVerification
  module Plans
    class Build
      # @spec LAYERED-VERIFY-021
      CHECKS = %w[linkage_freshness business_to_model business_to_spec spec_to_code model_to_code semantic_audit formal_verification].freeze
      def self.call(...) = new(...).call
      def initialize(obligations:, model: nil, requested_checks: [])
        @obligations, @model, @requested_checks = obligations, model, requested_checks.map(&:to_s)
      end
      def call
        invalid_checks = requested_checks - CHECKS
        raise ArgumentError, "unknown verification checks: #{invalid_checks.join(", ")}" if invalid_checks.any?

        selected = requested_checks.presence || inferred_checks
        { "selected_checks" => selected, "exclusions" => exclusions(selected), "required_inputs" => selected.index_with { |check| check == "formal_verification" ? %w[module config] : [ "obligation scope", "target revision" ] }, "assumptions" => [ "Checks assess the declared bounded scope and revision." ], "resource_expectations" => { "model" => model.present? }, "residual_gaps" => exclusions(selected).values }
      end
      private
      attr_reader :obligations, :model, :requested_checks
      def inferred_checks
        ([ "linkage_freshness" ] + obligations.flat_map { |obligation| obligation.correspondence_claims.pluck(:claim_type) } + (model.present? ? [ "formal_verification" ] : [])).uniq
      end
      def exclusions(selected)
        CHECKS.index_with { |check| check.in?(selected) ? "selected for this scope" : (check == "formal_verification" && model.blank? ? "no declared formal model" : "not selected because the declared scope has no matching correspondence claim") }
      end
    end
  end
end
