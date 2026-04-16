# frozen_string_literal: true

module Automation
  # Automation commands/actions — the executable side of an automation
  # decision.
  #
  # At this stage the action vocabulary is intentionally the same as the
  # decision vocabulary: strategies emit Automation::Decision values and
  # executors (jobs, Temporal activities) consume them as actions. This
  # alias exists so callers that think in terms of "what to execute" have
  # a name for that role, and so later phases can evolve action semantics
  # independently without renaming every call site.
  Action = Decision
end
