# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-021
      def self.call(...) = new(...).call

      def initialize(project:, user:, obligations:, sources:, target_revision:, budget:, runner_resolver: AgentRuns::RunnerResolver)
        @project, @user, @obligations, @sources = project, user, obligations, sources
        @target_revision, @budget, @runner_resolver = target_revision, budget, runner_resolver
      end

      def call
        runner_id, agent_type = resolve_runner
        AgentRun.create!(
          project:, initiating_user: user, runner_id:, agent_type:, goal: "layered_verification_audit",
          review_depth_snapshot: project.effective_review_depth, status: "queued", trigger_type: "manual",
          external_metadata: metadata
        ).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :project, :user, :obligations, :sources, :target_revision, :budget, :runner_resolver

      def resolve_runner = runner_resolver.call(project: project, goal: "layered_verification_audit")

      def metadata
        {
          "obligation_ids" => obligations.map(&:id), "sources" => sources, "target_revision" => target_revision,
          "budget" => budget, "initiating_trigger" => "manual_audit",
          "verification_plan" => Plans::Build.call(obligations:, sources:)
        }
      end
    end
  end
end
