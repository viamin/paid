# frozen_string_literal: true

module LayeredVerification
  module Audits
    class Request
      # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
      InvalidRequestError = Class.new(ArgumentError)

      def self.call(...)
        new(...).call
      end

      def initialize(user:, project:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
        @user = user
        @project = project
        @obligation_ids = normalized_values(obligation_ids)
        @source_references = normalized_values(source_references)
        @target_revision = target_revision.to_s.strip
        @budget_tokens = Integer(budget_tokens)
      rescue ArgumentError, TypeError
        raise InvalidRequestError, "audit budget must be a positive integer"
      end

      def call
        validate!
        AuditAccess.authorize!(user:, project:)

        AgentRun.create!(
          project:,
          initiating_user: user,
          agent_type: resolved_agent_type,
          runner: resolved_runner,
          goal: "layered_verification_audit",
          status: "queued",
          trigger_type: "manual",
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: { "layered_verification_audit" => request_snapshot }
        ).tap { ProcessRunQueueJob.perform_later }
      end

      private

      attr_reader :user, :project, :obligation_ids, :source_references, :target_revision, :budget_tokens

      def validate!
        raise InvalidRequestError, "audit obligation scope is required" if obligation_ids.empty?
        raise InvalidRequestError, "audit source references are required" if source_references.empty?
        raise InvalidRequestError, "audit target revision is required" if target_revision.blank?
        raise InvalidRequestError, "audit budget must be a positive integer" unless budget_tokens.positive?
      end

      def resolved_runner
        runner_selection.first
      end

      def resolved_agent_type
        runner_selection.last
      end

      def runner_selection
        @runner_selection ||= AgentRuns::RunnerResolver.call(project:, goal: "layered_verification_audit")
      end

      def request_snapshot
        {
          "obligation_ids" => obligation_ids,
          "source_references" => source_references,
          "target_revision" => target_revision,
          "budget_tokens" => budget_tokens,
          "requested_at" => Time.current.iso8601
        }
      end

      def normalized_values(values)
        Array(values).filter_map { |value| value.to_s.strip.presence }.uniq
      end
    end
  end
end
