# frozen_string_literal: true

namespace :intent_conformance do
  namespace :shadow_evaluation do
    desc "Execute the real intent-conformance reviewer for a frozen shadow evaluation " \
      "(usage: bin/rails 'intent_conformance:shadow_evaluation:execute[<id>]'). " \
      "Records actual verdicts, failures, and cost; retries cases without an evaluated verdict."
    task :execute, [ :shadow_evaluation_id ] => :environment do |_task, args|
      evaluation = IntentConformanceShadowEvaluation.find(args.fetch(:shadow_evaluation_id))
      TenantContext.apply!(evaluation.project.account)

      result = IntentConformance::ShadowEvaluation::ExecuteReviewer.call(evaluation: evaluation)
      IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if result.success?

      if result.success?
        puts "executed=#{result.executed} failed=#{result.failed} status=#{evaluation.reload.status}"
      else
        puts result.error
        exit 1
      end
    ensure
      TenantContext.clear!
    end
  end
end
