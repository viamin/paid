# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Execute the real intent-conformance reviewer for a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "Records actual verdicts, failures, and cost; retries cases without an evaluated verdict."
    # Drives the same queued→running→terminal lifecycle as the UI action
    # (#4642): the enqueue validations and dedup claim run first, then the
    # job performs inline so the command still reports the terminal outcome.
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    task :execute, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation, account = TenantContext.with_system_access do
        evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
        [ evaluation, evaluation.project.account ]
      end
      TenantContext.apply!(account)

      enqueued = IntentConformance::ShadowEvaluation::EnqueueExecution.call(evaluation: evaluation)
      unless enqueued.success?
        puts enqueued.error
        exit 1
      end
      IntentConformance::ShadowEvaluations::ExecuteJob.perform_now(evaluation.id)

      progress = evaluation.reload.execution_progress
      puts "executed=#{progress[:evaluated]} total=#{progress[:total]} status=#{evaluation.status}"
    ensure
      TenantContext.clear!
    end

    desc "Request cancellation of a queued/running shadow evaluation execution " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:cancel[<id>]'). " \
      "Honored between cases; collected evidence is preserved."
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    task :cancel, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation, account = TenantContext.with_system_access do
        evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
        [ evaluation, evaluation.project.account ]
      end
      TenantContext.apply!(account)

      result = IntentConformance::ShadowEvaluation::CancelExecution.call(evaluation: evaluation)
      unless result.success?
        puts result.error
        exit 1
      end
      puts "cancellation requested for shadow evaluation #{evaluation.id}"
    ensure
      TenantContext.clear!
    end
  end
end
