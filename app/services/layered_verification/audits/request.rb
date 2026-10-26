# frozen_string_literal: true

module LayeredVerification
  module Audits
    # The one audit-only admission boundary shared by project, chat, and MCP UI.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      Dispatch = Data.define(:run, :dispatch)

      def self.call(...) = new(...).call

      def initialize(project:, actor:, obligation_ids:, source_references:, target_revision:, budget_tokens:, trigger:)
        @project = project
        @actor = actor
        @obligation_ids = Array(obligation_ids).map(&:to_i).uniq
        @source_references = Array(source_references).map(&:to_s).reject(&:blank?).uniq
        @target_revision = target_revision.to_s
        @budget_tokens = budget_tokens.to_i
        @trigger = trigger.to_s
      end

      def call
        AuditAccess.authorize!(user: actor, project:)
        validate!
        Dispatch.new(run: create_run!, dispatch: dispatch_metadata)
      end

      private

      attr_reader :project, :actor, :obligation_ids, :source_references, :target_revision, :budget_tokens, :trigger

      def validate!
        raise ArgumentError, "Select at least one in-scope obligation" if obligations.empty?
        raise ArgumentError, "At least one source reference is required" if source_references.empty?
        raise ArgumentError, "A target revision is required" if target_revision.blank?
        raise ArgumentError, "Budget must be positive" unless budget_tokens.positive?
      end

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a.tap do |records|
          raise ArgumentError, "Every selected obligation must belong to this project" unless records.size == obligation_ids.size
        end
      end

      def create_run!
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
        AgentRun.create!(
          project:,
          initiating_user: actor,
          runner_id:,
          agent_type:,
          goal: "layered_verification_audit",
          status: "queued",
          trigger_type: "manual",
          base_commit_sha: target_revision,
          external_metadata: { "layered_verification" => dispatch_metadata }
        ).tap { ProcessRunQueueJob.perform_later }
      end

      def dispatch_metadata
        {
          "obligation_ids" => obligations.map(&:id),
          "scope" => obligations.map { |obligation| obligation.slice("external_identity", "scope_description", "approval_state", "external_revision") },
          "source_references" => source_references,
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens,
          "trigger" => trigger,
          "initiating_user_id" => actor.id
        }
      end
    end
  end
end
