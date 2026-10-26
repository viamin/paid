# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Creates the single, issue-less audit run used by the project action,
    # contextual chat, and MCP. It deliberately captures only investigation
    # inputs; the audit workflow has no authority to start a repair.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      class InvalidScopeError < StandardError; end

      def self.call(...) = new(...).call

      def initialize(project:, user:, obligation_ids:, target_revision:, budget_tokens:)
        @project = project
        @user = user
        @obligation_ids = Array(obligation_ids).map(&:to_i).uniq.sort
        @target_revision = target_revision.to_s
        @budget_tokens = Integer(budget_tokens)
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate_request!
        AgentRun.create!(run_attributes).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :budget_tokens, :obligation_ids, :project, :target_revision, :user

      def validate_request!
        raise InvalidScopeError, "select at least one obligation" if obligation_ids.empty?
        raise InvalidScopeError, "target revision is required" if target_revision.blank?
        raise InvalidScopeError, "budget must be positive" unless budget_tokens.positive?
        raise InvalidScopeError, "scope includes an obligation outside this project" unless obligations.count == obligation_ids.size
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids)
      end

      def run_attributes
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        {
          project:,
          initiating_user: user,
          runner_id:,
          agent_type:,
          goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth,
          status: "queued",
          trigger_type: "manual",
          external_metadata: { "layered_verification" => request_snapshot }
        }
      end

      def request_snapshot
        {
          "obligation_ids" => obligation_ids,
          "sources" => obligations.order(:id).map { |obligation| source_for(obligation) },
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens,
          "initiating_user_id" => user.id,
          "trigger" => "manual"
        }
      end

      def source_for(obligation)
        {
          "id" => obligation.id,
          "external_identity" => obligation.external_identity,
          "external_revision" => obligation.external_revision,
          "scope" => obligation.scope_description,
          "approval_state" => obligation.approval_state
        }
      end
    end
  end
end
