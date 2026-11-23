# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Dispatches the successor run for an admitted resumption (see
    # LayeredVerification::Resumption for the admission checks). The successor
    # carries the validated scope metadata plus the resumption decision, so
    # execution reuses only evidence the admission decision admitted and never
    # replays a repair mutation.
    # @spec LAYERED-VERIFY-020
    class Resume
      def self.call(...) = new(...).call

      def initialize(agent_run:, user:, decision:)
        @agent_run = agent_run
        @user = user
        @decision = decision
      end

      def call
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: agent_run.goal)
        successor = nil
        AgentRun.transaction do
          # Re-admission takes the same project-row lock as Request#call so a
          # resume cannot slip past the overlapping-active-audit rule.
          project.lock!
          raise Request::DuplicateAuditError, "an audit for this scope and revision is already active" if duplicate_audit?

          successor = AgentRun.create!(run_attributes(runner_id, agent_type))
        end
        ProcessRunQueueJob.perform_later
        successor
      end

      private

      attr_reader :agent_run, :decision, :user

      def project
        agent_run.project
      end

      def metadata
        agent_run.external_metadata.fetch("layered_verification")
      end

      def duplicate_audit?
        Request.active_run_for_identity?(project:, goal: agent_run.goal,
          obligation_ids: Array(metadata.fetch("obligation_ids")), target_revision: metadata.fetch("target_revision"))
      end

      def run_attributes(runner_id, agent_type)
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: agent_run.goal,
          issue_id: agent_run.issue_id, custom_prompt: agent_run.custom_prompt,
          source_pull_request_number: agent_run.source_pull_request_number,
          status: "queued", trigger_type: "manual", base_commit_sha: metadata.fetch("target_revision"),
          review_depth_snapshot: agent_run.review_depth_snapshot,
          originating_audit_run_id: agent_run.originating_audit_run_id,
          external_metadata: agent_run.external_metadata.merge("layered_verification" => resumed_metadata)
        }
      end

      def resumed_metadata
        metadata.merge(
          "budget" => decision.remaining_budget,
          "impact" => {
            "reused_check_result_ids" => decision.reusable_result_ids,
            "invalidated_check_result_ids" => decision.invalidated_result_ids,
            "limitations" => decision.limitations
          },
          "resumption" => {
            "resumed_from_run_id" => agent_run.id, "resumed_at" => Time.current.iso8601, "requested_by_id" => user.id
          }
        )
      end
    end
  end
end
