# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Admits one bounded, investigation-only audit. The dispatch record is the
    # durable preview: it preserves the exact resolved scope, sources,
    # revision, budget, and initiating user without granting repair authority.
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
      def self.call(...) = new(...).call

      def initialize(user:, project:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
        @user = user
        @project = project
        @obligation_ids = Array(obligation_ids).map(&:to_i).uniq.sort
        @source_references = Array(source_references).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        @target_revision = target_revision.to_s.strip
        @budget_tokens = budget_tokens.to_i
      end

      def call
        AuditAccess.authorize!(user:, project:)
        validate!
        run = create_run
        ProcessRunQueueJob.perform_later
        run
      end

      private

      attr_reader :budget_tokens, :obligation_ids, :project, :source_references, :target_revision, :user

      def validate!
        raise ArgumentError, "at least one obligation is required" if obligation_ids.empty?
        raise ArgumentError, "source references are required" if source_references.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget_tokens must be positive" unless budget_tokens.positive?
        raise ActiveRecord::RecordNotFound unless project.layered_verification_obligations.where(id: obligation_ids).count == obligation_ids.length
      end

      def create_run
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:,
          initiating_user: user,
          runner_id:,
          agent_type: agent_type || "claude_code",
          goal: "layered_verification_audit",
          base_commit_sha: target_revision,
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: { "layered_verification_audit" => dispatch_context },
          status: "queued",
          trigger_type: "manual"
        )
      end

      def dispatch_context
        {
          "obligation_ids" => obligation_ids,
          "source_references" => source_references,
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens,
          "initiating_user_id" => user.id,
          "trigger" => "manual"
        }
      end
    end
  end
end
