# frozen_string_literal: true

# Executes one prerequisite-evidence validation generation (#4643). The job
# is the durable progress surface between the operator's Inbox action and the
# bounded executor; the validation row carries all state, so a lost job never
# loses evidence and a cancelled row is never executed.
# @spec PREREQ-EVIDENCE-002 @spec PREREQ-EVIDENCE-007
class PrerequisiteValidationJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :low_priority
  self.perform_timeout = 30.minutes

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "prerequisite_validation_#{arguments.first}" }
  )

  discard_on ActiveRecord::RecordNotFound

  def perform(prerequisite_validation_id)
    validation = TenantContext.with_system_access do
      PrerequisiteValidation.find(prerequisite_validation_id)
    end
    return unless validation.status == "pending"

    TenantContext.with(validation.account) do
      report = Prerequisites::CapabilityReport.call(project: validation.project)
      Prerequisites::ExecuteValidation.call(validation, capability_report: report)
    end
  end
end
