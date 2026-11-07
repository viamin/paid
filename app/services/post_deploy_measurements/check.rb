# frozen_string_literal: true

module PostDeployMeasurements
  # One allowlisted post-deploy check definition. `baseline` is recorded for
  # interpretation only — it is never success evidence; `target` is the
  # count that satisfies the criterion; `capabilities` names the tenant read
  # capabilities the executor must probe first; `measurer` responds to
  # `.measure(project:)` and returns counts plus scope.
  # @spec POST-DEPLOY-001
  Check = Data.define(:key, :version, :criterion, :baseline, :target, :capabilities, :measurer)
end
