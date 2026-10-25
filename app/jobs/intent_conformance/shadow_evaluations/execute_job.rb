# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluations
    # Background execution of the frozen shadow-evaluation corpus (#4642).
    # The HTTP request only authorizes and enqueues this job; the corpus
    # never runs inside a web request. The job owns the queued→running→
    # terminal lifecycle: it honors an operator cancellation before starting,
    # delegates per-case work to the shared ExecuteReviewer service (freeze,
    # corpus-digest, reviewer-identity, and advisory-lock semantics
    # unchanged), compiles/attaches the report through CompileReport on
    # every terminal outcome with recorded runs, and releases its queued
    # claim when it does not own the record's state — so no evaluation is
    # left stranded as queued/running.
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class ExecuteJob < ApplicationJob
      include GoodJob::ActiveJobExtensions::Concurrency

      queue_as :default

      # One execution per evaluation at a time: duplicate enqueues (racing
      # submissions that both passed the status claim) queue up instead of
      # running concurrently; the evaluated-verdict skip makes the loser a
      # no-op, so completed-case spend is never repeated.
      good_job_control_concurrency_with(
        total_limit: 1,
        key: ->(job) { "intent_conformance_shadow_evaluation_execute_#{job.arguments.first}" }
      )

      discard_on ActiveRecord::RecordNotFound

      # Tenant resolution for ApplicationJob's around_perform: the argument
      # is the evaluation id, so resolve through its project's account
      # instead of the project/agent-run id conventions.
      def tenant_account
        IntentConformanceShadowEvaluation.includes(:project).find_by(id: arguments.first)&.project&.account
      end

      def perform(evaluation_id)
        evaluation = IntentConformanceShadowEvaluation.find(evaluation_id)

        # Cancellation requested while queued: honor it before any paid
        # reviewer invocation, preserving whatever evidence already exists.
        # Fresh row read — the in-memory instance may predate the request.
        if IntentConformanceShadowEvaluation.where(id: evaluation_id).pick(:cancel_requested_at).present?
          IntentConformance::ShadowEvaluation::CancelExecution.finalize(evaluation.reload,
            reason: "cancelled by operator before execution started — collected evidence preserved")
          return
        end

        result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)

        if result.success?
          IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation.runs.exists?
        elsif result.unowned?
          release_queued_claim(evaluation, result.error)
        elsif owns_claim?(evaluation)
          evaluation.update!(status: "failed", last_failure_reason: result.error)
        end
      end

      private

      # A queued claim this job made can be released when another holder
      # owns the actual execution; any other state belongs to that holder
      # (a live executor or the recovery sweep) and is left untouched.
      def release_queued_claim(evaluation, error)
        return unless evaluation.reload.queued?

        idle = evaluation.runs.exists? ? "partial" : "frozen"
        evaluation.update!(status: idle, last_failure_reason: error)
      end

      def owns_claim?(evaluation)
        evaluation.reload.execution_active?
      end
    end
  end
end
