# frozen_string_literal: true

require "digest"

module LayeredVerification
  module Audits
    # Persists the immutable review basis for one completed audit. The package
    # is deliberately descriptive: recording or later approving it never
    # authorizes a repair or release.
    #
    # @spec LAYERED-VERIFY-023
    class RecordReviewPackage
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
        audit.project.with_lock { create_package }
      end

      private

      attr_reader :audit, :check_results, :findings, :obligations

      def next_revision
        audit.project.layered_verification_review_packages.maximum(:package_revision).to_i + 1
      end

      def create_package
        LayeredVerificationReviewPackage.create!(
          project: audit.project,
          agent_run: audit.agent_run,
          package_revision: next_revision,
          digest: digest,
          obligation_revisions: obligation_revisions,
          scope: scope,
          plan_revision: audit.plan_revision,
          check_result_references: check_result_references,
          approvals: approvals,
          decisions: decisions
        )
      end

      def digest
        Digest::SHA256.hexdigest(
          {
            "obligation_revisions" => obligation_revisions,
            "scope" => scope,
            "plan_revision" => audit.plan_revision,
            "check_result_references" => check_result_references,
            "approvals" => approvals,
            "decisions" => decisions
          }.to_json
        )
      end

      def obligation_revisions
        obligations.map do |obligation|
          {
            "external_identity" => obligation.external_identity,
            "external_revision" => obligation.external_revision,
            "approval_state" => obligation.approval_state
          }
        end
      end

      def scope
        {
          "description" => audit.scope_description,
          "sources" => audit.sources,
          "target_revision" => audit.target_revision,
          "budget" => audit.budget
        }
      end

      def check_result_references
        check_results.map do |result|
          { "check_result_id" => result.id, "input_revision" => result.input_revision }
        end
      end

      def decisions
        findings.map do |finding|
          {
            "finding_id" => finding.id,
            "status" => finding.status,
            "deferral_reason" => finding.deferral_reason,
            "resolved_at" => finding.resolved_at
          }.compact
        end
      end

      def approvals
        obligations.filter_map do |obligation|
          next unless obligation.approval_state == "approved"

          {
            "external_identity" => obligation.external_identity,
            "approved_revision_reference" => obligation.approved_revision_reference
          }.compact
        end
      end
    end
  end
end
