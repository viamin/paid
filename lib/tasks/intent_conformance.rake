# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Execute the real intent-conformance reviewer for a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "Queues the durable reviewer worker; retries only cases without an evaluated verdict."
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-010
    task :execute, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation, account = TenantContext.with_system_access do
        evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
        [ evaluation, evaluation.project.account ]
      end
      TenantContext.apply!(account)

      result = IntentConformance::ShadowEvaluation::ScheduleExecution.call(evaluation: evaluation)

      if result.success?
        puts "queued=#{result.enqueued?} status=#{evaluation.reload.status}"
      else
        puts result.error
        exit 1
      end
    ensure
      TenantContext.clear!
    end
  end
end
