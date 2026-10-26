# frozen_string_literal: true

module LayeredVerification
  module Audits
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    class Request
      Result = Data.define(:agent_run, :scope, :budget, :trigger)

      def self.call(...) = new(...).call

      def initialize(project:, actor:, scope:, source_references:, target_revision:, budget:)
        @project = project
        @actor = actor
        @scope = Array(scope).map(&:to_s).reject(&:blank?).uniq
        @source_references = Array(source_references).map(&:to_s).reject(&:blank?).uniq
        @target_revision = target_revision.to_s
        @budget = Integer(budget)
      end

      def call
        AuditAccess.authorize!(user: actor, project:)
        validate!
        resolve_scope!
        run = AgentRun.create!(project:, initiating_user: actor, goal: "layered_verification_audit",
          agent_type: "codex", trigger_type: "manual", token_limit_status: "ok",
          custom_prompt: "Bounded layered-verification audit; coordinator-only report generation.",
          reconciliation: { "layered_verification_audit" => request_snapshot })
        ProcessRunQueueJob.perform_later
        Result.new(agent_run: run, scope:, budget:, trigger: "manual")
      end

      private

      attr_reader :actor, :budget, :project, :scope, :source_references, :target_revision

      def validate!
        raise ArgumentError, "scope is required" if scope.empty?
        raise ArgumentError, "source references are required" if source_references.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be positive" unless budget.positive?
      end

      def resolve_scope!
        missing = scope - project.layered_verification_obligations.where(external_identity: scope).pluck(:external_identity)
        raise ArgumentError, "unknown obligation scope: #{missing.join(', ')}" if missing.any?
      end

      def request_snapshot
        { "scope" => scope, "source_references" => source_references, "target_revision" => target_revision,
          "budget" => budget, "initiating_user_id" => actor.id, "trigger" => "manual", "progress" => "queued" }
      end
    end
  end
end
