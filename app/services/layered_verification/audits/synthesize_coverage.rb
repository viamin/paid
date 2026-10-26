# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Synthesizes the audit's coverage and its two review views from the
    # recorded check results.
    #
    # Coverage keeps three dimensions separate: the check's execution state,
    # the check's coverage of the obligation, and the obligation's own
    # coverage. A contradicted check makes the obligation contradicted. A
    # supported check supports the obligation; checks that stayed unresolved
    # are disclosed as remaining gaps rather than silently dropped. An
    # obligation with no supporting and no contradicting check stays
    # unresolved — never supported.
    #
    # @spec LAYERED-VERIFY-024
    class SynthesizeCoverage
      Report = Data.define(:coverage, :business_intent_validation, :verification_coverage) do
        def clean? = coverage.all? { |entry| entry["verdict"] == "supported" }
      end

      def self.call(...)
        new(...).call
      end

      def initialize(audit:, obligations:, check_results:, findings: [])
        @audit = audit
        @obligations = obligations
        @check_results = check_results
        @findings = findings
      end

      def call
        Report.new(
          coverage: coverage,
          business_intent_validation: business_intent_validation,
          verification_coverage: verification_coverage
        )
      end

      private

      attr_reader :audit, :check_results, :findings, :obligations

      def coverage
        obligations.map { |obligation| coverage_entry(obligation) }
      end

      def coverage_entry(obligation)
        results = results_for(obligation)

        {
          "obligation_id" => obligation.id,
          "external_identity" => obligation.external_identity,
          "framework" => obligation.framework,
          "approval_state" => obligation.approval_state,
          "verdict" => verdict_for(results),
          "check_outcomes" => results.map { |result| outcome_for(result) },
          "remaining_gaps" => remaining_gaps(obligation, results)
        }
      end

      def results_for(obligation)
        check_results.select { |result| result.obligation_id == obligation.id }
      end

      def verdict_for(results)
        return "contradicted" if results.any? { |result| result.obligation_coverage == "contradicted" }
        return "supported" if results.any? { |result| result.obligation_coverage == "supported" }

        "unresolved"
      end

      def outcome_for(result)
        {
          "check_result_id" => result.id,
          "producer" => result.producer,
          "execution_state" => result.execution_state,
          "obligation_coverage" => result.obligation_coverage,
          "input_revision" => result.input_revision,
          "evidence_ref" => result.evidence_ref,
          "limitations" => result.limitations
        }
      end

      def remaining_gaps(obligation, results)
        gaps = results.filter_map do |result|
          next unless result.obligation_coverage == "unresolved"

          "#{result.producer}: #{result.limitations}"
        end
        gaps << "The obligation is not approved in its canonical framework (#{obligation.approval_state})." unless obligation.approval_state == "approved"
        gaps
      end

      # The business-intent view answers "what does the business owner have to
      # decide?" — the obligation's scope, its canonical source, the passages
      # at issue, the observed behavior, and whether a decision is open.
      def business_intent_validation
        obligations.map do |obligation|
          obligation_findings = findings_for(obligation)

          {
            "external_identity" => obligation.external_identity,
            "scope" => obligation.scope_description,
            "framework" => obligation.framework,
            "approval_state" => obligation.approval_state,
            "source_reference" => obligation.external_identity,
            "source_passages" => obligation_findings.flat_map { |finding| Array(finding.source_passages) }.uniq,
            "observed_behavior" => obligation_findings.map(&:observed_behavior).uniq.join("\n\n"),
            "decision_needed" => obligation_findings.first&.question,
            "open_findings" => obligation_findings.count { |finding| finding.unresolved? }
          }
        end
      end

      # The verification-coverage view answers "what was checked, what does it
      # establish, and what is still missing?" — the selected checks and their
      # fit, the recorded outcomes, the assumptions, the omissions, the cost,
      # and the next actions.
      def verification_coverage
        obligations.map do |obligation|
          results = results_for(obligation)
          planned = planned_checks_for(obligation)

          {
            "external_identity" => obligation.external_identity,
            "selected_checks" => planned,
            "check_outcomes" => results.map { |result| outcome_for(result) },
            "assumptions" => planned.flat_map { |check| Array(check["assumptions"]) }.uniq,
            "omissions" => audit.plan.fetch("exclusions", []),
            "cost" => { "tokens" => results.sum { |result| result.cost.to_h["tokens"].to_i } },
            "findings" => findings_for(obligation).map(&:id),
            "next_actions" => findings_for(obligation).flat_map(&:owner_actions).uniq
          }
        end
      end

      def planned_checks_for(obligation)
        Array(audit.plan["selected_checks"]).select do |check|
          check["obligation_external_identity"] == obligation.external_identity
        end
      end

      def findings_for(obligation)
        findings.select { |finding| finding.obligation_id == obligation.id }
      end
    end
  end
end
