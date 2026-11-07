# frozen_string_literal: true

namespace :trusted_measurements do
  desc "Run one allowlisted, read-only, bounded trusted measurement for a project (#4907). " \
    "Required: PROJECT_ID=<id>, TARGET_REVISION=<revision>. Optional: CHECK_KEY (default " \
    "agent_planning_hold_reconciliation_closed_count), EXTERNAL_ISSUE_NUMBER (default 4812), " \
    "CRITERION_KEY (default closed_planning_hold_notifications_cleared). Runs only when " \
    "PAID_DEPLOYED_REVISION exactly matches TARGET_REVISION. Idempotent — repeat " \
    "invocations against the same deployed revision update the same attempt row."
  task run_check: :environment do
    project = TenantContext.with_system_access { Project.find(Integer(ENV.fetch("PROJECT_ID"))) }
    check_key = ENV.fetch("CHECK_KEY", "agent_planning_hold_reconciliation_closed_count")
    external_issue_number = Integer(ENV.fetch("EXTERNAL_ISSUE_NUMBER", "4812"))
    criterion_key = ENV.fetch("CRITERION_KEY", "closed_planning_hold_notifications_cleared")
    expected_deployed_revision = ENV.fetch("TARGET_REVISION")

    TenantContext.with(project.account) do
      attempt = TrustedMeasurements::RunCheck.call(
        project:, check_key:, external_issue_number:, criterion_key:, expected_deployed_revision:
      )

      unless attempt
        puts "#{check_key.inspect} is not an allowlisted trusted measurement check; no attempt was recorded."
        next
      end

      puts "Trusted measurement #{check_key} for ##{external_issue_number} (#{criterion_key}):"
      puts "  status:              #{attempt.status}"
      puts "  deployed_revision:   #{attempt.deployed_revision.inspect}"
      puts "  result:              #{attempt.result}"
      puts "  failure_reason:      #{attempt.failure_reason}" if attempt.failure_reason
    end
  end
end
