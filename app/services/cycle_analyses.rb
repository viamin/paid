# frozen_string_literal: true

# Operator-started investigation of one persisted dependency-cycle occurrence,
# bounded to attempt a GitHub declaration repair only when the recommendation
# clears the explicit AUTO-PICK-QUEUE-021 obvious-correction threshold; every
# other outcome remains exactly as read-only as the original #4804 contract.
# Durable evidence lives on a synthetic AgentRun so ordinary run
# authorization, status reporting, audit, and agent_harness routing are reused.
module CycleAnalyses
  METADATA_KEY = "cycle_analysis"
  RESULT_KEY = "cycle_analysis"

  class InvalidResponse < AgentHarness::CommandExecutionError; end
end
