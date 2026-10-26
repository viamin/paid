# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Dispatches a requested audit: it creates the issue-less audit run that
    # carries the project, the resolved scope, and the budget, and starts the
    # audit's execution.
    #
    # The audit run is the only execution this path creates. Nothing here
    # enqueues a repair: an audit that finds a discrepancy never starts
    # corrective work on its own.
    #
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013 @spec LAYERED-VERIFY-020
    class Dispatch
      AlreadyDispatchedError = Class.new(StandardError)

      def self.call(...)
        new(...).call
      end

      def initialize(audit:, user:, trigger_type: nil, runner_resolver: nil, enqueue: true)
        @audit = audit
        @user = user
        @trigger_type = trigger_type
        @runner_resolver = runner_resolver
        @enqueue = enqueue
      end

      def call
        AuditAccess.authorize!(user:, project:)
        raise AlreadyDispatchedError, "this audit was already dispatched" if audit.agent_run.present?

        run = create_run
        audit.update!(agent_run: run, status: "dispatched", trigger_type: trigger_type || audit.trigger_type)
        LayeredVerificationAuditExecuteJob.perform_later(audit.id) if enqueue

        run
      end

      private

      attr_reader :audit, :enqueue, :runner_resolver, :trigger_type, :user

      def project
        audit.project
      end

      def create_run
        runner_id, agent_type = resolved_runner

        AgentRun.create!(
          project: project,
          initiating_user: user,
          runner_id: runner_id,
          agent_type: agent_type,
          goal: "layered_verification_audit",
          custom_prompt: prompt,
          review_depth_snapshot: project.effective_review_depth,
          external_metadata: { "layered_verification" => scope_metadata },
          status: "running",
          started_at: Time.current,
          trigger_type: "manual"
        )
      end

      def resolved_runner
        resolver = runner_resolver || AgentRuns::RunnerResolver
        resolver.call(project: project, goal: "layered_verification_audit")
      end

      def prompt
        "Bounded layered-verification audit.\n\nScope: #{audit.scope_description}\n\n" \
          "Sources: #{Array(audit.sources).map { |source| source['path'] }.join(', ')}\n" \
          "Target revision: #{audit.target_revision}"
      end

      def scope_metadata
        {
          "scope_description" => audit.scope_description,
          "sources" => audit.sources,
          "target_revision" => audit.target_revision,
          "budget" => audit.budget,
          "audit_id" => audit.id
        }
      end
    end
  end
end
