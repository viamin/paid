# frozen_string_literal: true

namespace :post_deploy_checks do
  desc "Run one allowlisted, read-only post-deploy check against a project's live data. " \
    "Required: PROJECT_ID=<id> CHECK_KEY=<key> DEPLOYED_REVISION=<sha>. " \
    "Optional: SOURCE_ISSUE_NUMBER=<github_number> to gate on Issue#deployed?; " \
    "PREREQUISITE_NOTIFICATION_ID=<id> PREREQUISITE_IDENTITY=<identity> to feed a passing result " \
    "into that notification's existing partial-closeout prerequisite occurrence. " \
    "Idempotent — re-running with the same PROJECT_ID/CHECK_KEY/DEPLOYED_REVISION returns the " \
    "already-recorded attempt instead of re-executing it."
  task run: :environment do # @spec POST-DEPLOY-CHECK-009
    project = Project.find(Integer(ENV.fetch("PROJECT_ID")))
    check_key = ENV.fetch("CHECK_KEY")
    deployed_revision = ENV.fetch("DEPLOYED_REVISION")
    source_issue = project.issues.find_by(github_number: ENV["SOURCE_ISSUE_NUMBER"]) if ENV["SOURCE_ISSUE_NUMBER"].present?

    TenantContext.with(project.account) do
      run = PostDeployChecks::Run.call(check_key:, project:, deployed_revision:, source_issue:)

      puts "Post-deploy check \"#{check_key}\" for #{project.full_name} @ #{deployed_revision}:"
      puts "  status:         #{run.status}"
      puts "  result:         #{run.result}"
      puts "  failure_reason: #{run.failure_reason}" if run.failure_reason.present?

      notification_id = ENV["PREREQUISITE_NOTIFICATION_ID"]
      next if notification_id.blank?

      notification = Notification.find(Integer(notification_id))
      prerequisite_identity = ENV.fetch("PREREQUISITE_IDENTITY")
      submission = PostDeployChecks::FeedPrerequisiteEvidence.call(run:, notification:, prerequisite_identity:)
      puts "  prerequisite:   #{submission ? submission["outcome"] : "not applicable (stale occurrence or not current)"}"
      puts "  notification:   #{notification.reload.resolved_at ? "resolved" : "still active"}"
    end
  end
end
