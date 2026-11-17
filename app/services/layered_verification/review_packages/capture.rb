# frozen_string_literal: true

module LayeredVerification
  module ReviewPackages
    # Binds the audit's inputs into one immutable review package identity.
    # An unchanged replay reuses the existing revision; any changed bound
    # input creates a new revision and retains the prior record unchanged.
    # @spec LAYERED-VERIFY-023
    class Capture
      def self.call(...) = new(...).call

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def call
        return unless audit_metadata

        # Serialize captures per run so replayed and racing captures of the
        # same inputs resolve to one revision.
        agent_run.with_lock do
          bound = bound_inputs
          digest = LayeredVerificationReviewPackage.digest_for(bound)
          current = agent_run.review_packages.order(:revision_number).last
          return current if current&.package_digest == digest

          agent_run.review_packages.create!(
            project: agent_run.project, package_digest: digest,
            revision_number: current ? current.revision_number + 1 : 1, bound_inputs: bound
          )
        end
      end

      private

      attr_reader :agent_run

      def audit_metadata
        return unless agent_run.layered_verification_audit_goal?

        agent_run.external_metadata["layered_verification"]
      end

      def bound_inputs
        {
          "agent_run_id" => agent_run.id,
          "target_revision" => audit_metadata["target_revision"],
          "obligations" => scoped_obligations.map do |obligation|
            {
              "id" => obligation.id, "external_identity" => obligation.external_identity,
              "external_revision" => obligation.external_revision,
              "scope_description" => obligation.scope_description
            }
          end,
          "plan_revision" => LayeredVerificationReviewPackage.digest_for(audit_metadata["plan"] || {}),
          "check_result_ids" => contributing_result_ids,
          "approval_ids" => recorded_approvals.map(&:id),
          "inbox_decisions" => inbox_decisions
        }
      end

      def scoped_obligations
        agent_run.project.layered_verification_obligations.where(id: audit_metadata["obligation_ids"]).order(:id)
      end

      def contributing_result_ids
        LayeredVerificationCheckResult.where(agent_run:).order(:id).pluck(:id)
      end

      def recorded_approvals
        LayeredVerificationReviewApproval.joins(:package)
          .where(layered_verification_review_packages: { agent_run_id: agent_run.id })
          .order(:id).to_a
      end

      def inbox_decisions
        LayeredVerificationFinding.where(agent_run:).order(:id).filter_map do |finding|
          selected_action = finding.decision["selected_action"]
          decided_at = finding.decision["decided_at"]
          next unless selected_action.present? && decided_at.present?

          { "finding_id" => finding.id, "selected_action" => selected_action, "decided_at" => decided_at }
        end
      end
    end
  end
end
