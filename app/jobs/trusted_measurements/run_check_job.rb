# frozen_string_literal: true

module TrustedMeasurements
  # Runs one allowlisted trusted measurement for a project, after the target
  # revision is deployed. Tenant context is established automatically by
  # ApplicationJob from +project_id+ (see application_job.rb's
  # +project_id_first?+), so this job never calls TenantContext itself.
  # @spec TRUSTED-MEASUREMENTS-003
  class RunCheckJob < ApplicationJob
    queue_as :low_priority

    self.notification_subsystem = "trusted_measurements"

    discard_on ActiveRecord::RecordNotFound
    retry_on ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid,
      wait: :polynomially_longer, attempts: 5 do |job, error|
      job.notify_terminal_failure(error)
      raise error
    end

    def notification_project_id
      arguments.first
    end

    def perform(project_id, check_key:, external_issue_number:, criterion_key:)
      project = Project.find(project_id)
      RunCheck.call(project: project, check_key: check_key, external_issue_number: external_issue_number, criterion_key: criterion_key)
    end
  end
end
