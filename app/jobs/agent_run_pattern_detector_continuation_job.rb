# frozen_string_literal: true

# A performing detector can always enqueue its successor, even if a duplicate
# cron cycle start is waiting behind it; the shared concurrency key still
# serializes performs so detection chains never overlap.
# @spec RUN-OBSTACLE-006
# @spec RUN-OBSTACLE-007
class AgentRunPatternDetectorContinuationJob < AgentRunPatternDetectorJob
  good_job_control_concurrency_with(
    perform_limit: 1,
    key: "agent_run_pattern_detector"
  )
end
