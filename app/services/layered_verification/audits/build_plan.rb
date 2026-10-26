# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Assembles the verification plan an audit runs. The plan states the
    # selected checks and why they fit, the exclusions and why they were
    # omitted, the required inputs, assumptions, resource expectations, and the
    # residual gaps.
    #
    # The plan never imposes a minimum number of layers and never waives a
    # host policy: CI, security, branch protection, code review, and
    # approved-intent conformance run independently of any plan outcome.
    #
    # @spec LAYERED-VERIFY-021
    class BuildPlan
      HOST_POLICIES = %w[ci security branch_protection code_review approved_intent_conformance].freeze
      PRODUCERS = LayeredVerificationCheckResult::PRODUCERS

      Plan = Data.define(:document, :selected_checks, :exclusions, :residual_gaps)

      def self.call(...)
        new(...).call
      end

      def initialize(project:, obligations:, scope:, artifacts: {}, selector: nil)
        @project = project
        @obligations = obligations
        @scope = scope
        @artifacts = artifacts
        @selector = selector
      end

      def call
        selection = selected_checks
        document = {
          "revision" => 1,
          "obligation_external_identities" => obligations.map(&:external_identity),
          "failure_modes" => Array(selection["failure_modes"]),
          "selected_checks" => selected,
          "exclusions" => exclusions,
          "required_inputs" => required_inputs,
          "assumptions" => assumptions,
          "resource_expectations" => resource_expectations,
          "residual_gaps" => residual_gaps,
          "host_policies" => HOST_POLICIES,
          "host_policies_waivable" => false
        }

        Plan.new(
          document:,
          selected_checks: selected,
          exclusions: exclusions,
          residual_gaps: document["residual_gaps"]
        )
      end

      private

      attr_reader :artifacts, :obligations, :project, :scope, :selector

      def selection
        @selection ||= (selector&.call || LayeredVerification::Audits::SelectChecks.call(
          obligations: obligations,
          artifacts: artifacts,
          sources: scope.source_paths,
          producers: PRODUCERS
        ) || {})
      end

      def selected_checks
        @selected_checks ||= begin
          checks = Array(selection&.dig("checks")).first(max_checks)
          checks.map { |check| check.merge("inputs" => required_inputs_for(check)) }
        end
      end

      def exclusions
        @exclusions ||= Array(selection&.dig("exclusions"))
      end

      def residual_gaps
        gaps = Array(selection&.dig("residual_gaps"))
        gaps << "No check established coverage for the obligations in scope." if selected_checks.empty?
        gaps
      end

      def required_inputs
        scope.source_paths
      end

      def required_inputs_for(check)
        Array(check["required_inputs"])
      end

      def assumptions
        selected_checks.flat_map { |check| Array(check["assumptions"]) }.uniq
      end

      def resource_expectations
        {
          "max_checks" => max_checks,
          "tokens" => selected_checks.sum { |check| check.dig("resource_expectations", "tokens").to_i },
          "max_duration_seconds" => scope.budget["max_duration_seconds"]
        }
      end

      def max_checks
        @max_checks ||= scope.budget["max_checks"].to_i.clamp(1, ResolveScope::MAX_CHECKS)
      end
    end
  end
end
