# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Queue the real intent-conformance reviewer for a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "Same lifecycle as the UI action: the command enqueues the idempotent background job; " \
      "progress, cancellation, and the compiled report appear on the evaluation screen."
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    task :execute, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation, account = TenantContext.with_system_access do
        evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
        [ evaluation, evaluation.project.account ]
      end
      TenantContext.apply!(account)

      result = IntentConformance::ShadowEvaluation::EnqueueExecution.call(evaluation: evaluation)

      if result.success?
        puts "queued execution for evaluation #{evaluation.id} (attempt #{evaluation.execution_attempts}) — " \
          "progress, cancellation, and the report appear on the evaluation screen"
      else
        puts result.error
        exit 1
      end
    ensure
      TenantContext.clear!
    end
  end
end
