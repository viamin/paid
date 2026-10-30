# frozen_string_literal: true

# Read-only, operator-started investigation of one persisted dependency-cycle
# occurrence. Durable evidence lives on a synthetic AgentRun so ordinary run
# authorization, status reporting, audit, and agent_harness routing are reused.
module CycleAnalyses
  METADATA_KEY = "cycle_analysis"
  RESULT_KEY = "cycle_analysis"

  class InvalidResponse < AgentHarness::CommandExecutionError; end
end
