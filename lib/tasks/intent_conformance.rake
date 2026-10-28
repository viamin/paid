# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Queue the real intent-conformance reviewer for asynchronous execution of a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "A GoodJob worker records verdicts, failures, and cost and retries cases without an evaluated verdict."
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    task :execute, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation, account = TenantContext.with_system_access do
        evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
        [ evaluation, evaluation.project.account ]
      end
      TenantContext.apply!(account)

      result = IntentConformance::ShadowEvaluation::EnqueueExecution.call(
        evaluation: evaluation,
        actor: evaluation.created_by
      )

      if result.success?
        puts "execution_queued=#{result.enqueued} status=#{evaluation.reload.status}; GoodJob completes the evaluation asynchronously"
      else
        puts result.error
        exit 1
      end
    ensure
      TenantContext.clear!
    end
  end
end
