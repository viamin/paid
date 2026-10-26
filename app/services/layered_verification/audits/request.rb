# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates an investigation-only run. Execution, findings, and reports are
    # deliberately downstream concerns: creating this run never authorizes a repair.
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
      def self.call(...) = new(...).call

      def initialize(project:, user:, target_revision: nil, obligation_ids: nil)
        @project = project
        @user = user
        @target_revision = target_revision
        @obligation_ids = obligation_ids
      end

      def call
        AuditAccess.authorize!(user:, project:)
        AgentRun.create!(run_attributes)
      end

      private

      attr_reader :project, :user, :target_revision, :obligation_ids

      def run_attributes
        {
          project:,
          initiating_user: user,
          agent_type: "internal_agent",
          goal: "layered_verification_audit",
          trigger_type: "manual",
          status: "queued",
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: { "layered_verification_audit" => audit_snapshot }
        }
      end

      def audit_snapshot
        {
          "obligation_ids" => obligations.pluck(:id),
          "sources" => obligations.pluck(:external_identity),
          "target_revision" => target_revision.presence || obligations.pick(:external_revision),
          "token_budget" => project.account.default_max_tokens_per_run,
          "trigger" => "manual",
          "state" => "queued"
        }
      end

      def obligations
        @obligations ||= begin
          scope = project.layered_verification_obligations.order(:id)
          obligation_ids.present? ? scope.where(id: Array(obligation_ids)) : scope
        end
      end
    end
  end
end
