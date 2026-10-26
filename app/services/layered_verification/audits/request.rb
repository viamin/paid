# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Resolves the exact bounded audit request before it enters the normal run queue.
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-014
    class Request
      Result = Data.define(:agent_run, :scope, :target_revision, :budget, :sources)

      def self.call(...) = new(...).call

      def initialize(project:, actor:, obligation_ids:, source_references:, target_revision:, budget:, runner_resolver: AgentRuns::RunnerResolver)
        @project, @actor, @obligation_ids, @source_references, @target_revision, @budget, @runner_resolver =
          project, actor, obligation_ids, source_references, target_revision, budget, runner_resolver
      end

      def call
        AuditAccess.authorize!(user: actor, project:)
        validate_inputs!
        runner_id, agent_type = runner_resolver.call(project:, goal: "layered_verification_audit")
        run = AgentRun.create!(project:, initiating_user: actor, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          external_metadata: metadata)
        ProcessRunQueueJob.perform_later
        Result.new(agent_run: run, scope: obligations.map(&:scope_description), target_revision:, budget:, sources: source_references)
      end

      private

      attr_reader :project, :actor, :obligation_ids, :source_references, :target_revision, :budget, :runner_resolver

      def obligations
        @obligations ||= project.layered_verification_obligations.where(id: obligation_ids).order(:id).to_a.tap do |rows|
          raise ArgumentError, "every requested obligation must belong to the project" unless rows.size == obligation_ids.size
        end
      end

      def validate_inputs!
        raise ArgumentError, "at least one obligation is required" if obligation_ids.empty?
        raise ArgumentError, "at least one source reference is required" if source_references.empty?
        raise ArgumentError, "target revision is required" if target_revision.blank?
        raise ArgumentError, "budget must be a positive integer" unless budget.is_a?(Integer) && budget.positive?
      end

      def metadata
        { "layered_verification_audit" => { "obligation_ids" => obligations.map(&:id),
          "scope" => obligations.map(&:scope_description), "source_references" => source_references,
          "target_revision" => target_revision, "budget" => budget, "initiating_user_id" => actor.id } }
      end
    end
  end
end
