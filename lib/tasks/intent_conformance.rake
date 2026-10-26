# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Queue the real intent-conformance reviewer for a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "The job runs in the background with durable progress, cancellation, and recovery; " \
      "re-runs retry only cases without an evaluated verdict."
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
        puts result.already_active? ? "execution already queued or running (status=#{evaluation.reload.status})" : "execution queued — follow progress and cancellation on the evaluation screen"
      else
        puts result.error
        exit 1
      end
    ensure
      TenantContext.clear!
    end
  end
end
