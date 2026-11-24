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

      def initialize(agent_run:, user:)
        @agent_run = agent_run
        @user = user
      end

      def call
        AuditAccess.authorize!(user:, project:)
        @target_revision = resumed_target_revision
        runner_id, agent_type = AgentRuns::RunnerResolver.call(project:, goal: resumed_goal)
        successor = nil
        AgentRun.transaction do
          # Re-admission takes the same project-row lock as Request#call so a
          # resume cannot slip past the overlapping-active-audit rule.
          project.lock!
          raise Request::DuplicateAuditError, "an audit for this scope and revision is already active" if duplicate_audit?

          lock_obligations!
          @dependency_snapshot = DependencySnapshot.call(project:)
          @decision = Resumption.call(agent_run:, user:, dependencies: dependency_snapshot, target_revision:)
          successor = AgentRun.create!(run_attributes(runner_id, agent_type))
        end
        ProcessRunQueueJob.perform_later
        successor
      end

      private

      attr_reader :agent_run, :decision, :dependency_snapshot, :target_revision, :user

      def project
        agent_run.project
      end

      def metadata
        agent_run.external_metadata.fetch("layered_verification")
      end

      def duplicate_audit?
        Request.active_run_for_identity?(project:, goal: resumed_goal,
          obligation_ids: Array(metadata.fetch("obligation_ids")), target_revision:)
      end

      def lock_obligations!
        @obligations = project.layered_verification_obligations.where(id: metadata.fetch("obligation_ids")).lock.order(:id).to_a
      end

      def run_attributes(runner_id, agent_type)
        {
          project:, initiating_user: user, runner_id:, agent_type:, goal: resumed_goal,
          issue_id: agent_run.issue_id, custom_prompt: resumed_prompt,
          source_pull_request_number: agent_run.source_pull_request_number,
          status: "queued", trigger_type: "manual", base_commit_sha: target_revision,
          review_depth_snapshot: agent_run.review_depth_snapshot,
          originating_audit_run_id: resumed_originating_audit_run_id,
          external_metadata: agent_run.external_metadata.merge("layered_verification" => resumed_metadata)
        }
      end

      def resumed_metadata
        metadata.merge(
          "target_revision" => target_revision,
          "budget" => decision.remaining_budget,
          "input_revisions" => obligation_input_revisions,
          "dependencies" => dependency_snapshot,
          "impact" => {
            "reused_check_result_ids" => decision.reusable_result_ids,
            "invalidated_check_result_ids" => decision.invalidated_result_ids,
            "limitations" => decision.limitations
          },
          "resumption" => {
            "resumed_from_run_id" => agent_run.id, "resumed_at" => Time.current.iso8601, "requested_by_id" => user.id,
            "interrupted_goal" => agent_run.goal,
            "originating_audit_run_id" => agent_run.originating_audit_run_id
          }.compact
        )
      end

      def obligation_input_revisions
        @obligations.to_h { |obligation| [ obligation.id.to_s, obligation.external_revision ] }
      end

      # A repair may already have mutated canonical artifacts before its
      # interruption. Resume it through the report-only audit path so only the
      # remaining verification executes; never copy its mutation prompt.
      # @spec LAYERED-VERIFY-020
      def resumed_goal
        repair? ? "layered_verification_audit" : agent_run.goal
      end

      def resumed_prompt
        agent_run.custom_prompt unless repair?
      end

      def resumed_originating_audit_run_id
        agent_run.originating_audit_run_id unless repair?
      end

      def resumed_target_revision
        return metadata.fetch("target_revision") unless repair?

        revision = agent_run.result_commit_sha
        return revision if revision&.match?(/\A[0-9a-f]{40}\z/i)

        raise ArgumentError, "a repair requires a recorded post-mutation revision before resumption"
      end

      def repair? = agent_run.goal == "layered_verification_repair"
    end
  end
end
