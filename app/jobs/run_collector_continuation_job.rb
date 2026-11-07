# frozen_string_literal: true

# A running batch can always enqueue its successor, even if duplicate initial
# collection requests are waiting. The shared key still serializes execution.
# @spec KNOWLEDGE-014
class RunCollectorContinuationJob < RunCollectorBatchJob
  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "run_collectors_#{arguments[0]}_#{arguments[1]}" }
  )
end
