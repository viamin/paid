# frozen_string_literal: true

# Recovers eligible reviewed retry generations without restarting terminal runs.
# @spec STAGED-CLOSEOUT-ADOPTION-015
class CloseoutVerificationRetrySweepJob < ApplicationJob
  queue_as :maintenance

  BATCH_SIZE = 100

  def perform(after_run_id: nil, through_run_id: nil)
    TenantContext.with_system_access do
      through_run_id ||= candidates.maximum(:id)
      return unless through_run_id

      runs = candidates.where("agent_runs.id > ? AND agent_runs.id <= ?", after_run_id.to_i, through_run_id)
        .order(:id).limit(BATCH_SIZE).includes(project: :account).to_a
      runs.each { |run| TenantContext.with(run.project.account) { reconcile(run) } }
      self.class.perform_later(after_run_id: runs.last.id, through_run_id:) if runs.size == BATCH_SIZE
    end
  end

  private

  def candidates
    AgentRun.joins(:project, :issue).joins(<<~SQL.squish)
      INNER JOIN staged_closeout_mappings retry_mappings
        ON retry_mappings.id = agent_runs.closeout_mapping_id
       AND retry_mappings.project_id = agent_runs.project_id
       AND retry_mappings.issue_id = agent_runs.issue_id
       AND retry_mappings.account_id = projects.account_id
      INNER JOIN staged_closeout_enrollments retry_enrollments
        ON retry_enrollments.id = retry_mappings.staged_closeout_enrollment_id
       AND retry_enrollments.project_id = agent_runs.project_id
       AND retry_enrollments.enabled = TRUE
    SQL
      .where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL, synthetic: true, status: %w[completed failed])
      .where(projects: { active: true }, issues: { github_state: "open" })
      .where("retry_mappings.status = 'approved' AND retry_mappings.invalidated_at IS NULL")
      .where("retry_mappings.retry_policy->>'max_attempts' IN ('2', '3')")
  end

  def reconcile(run)
    if run.closeout_target_revision.present?
      CloseoutVerifications::AdmitLiveTarget.call(project: run.project, mapping_ids: [ run.closeout_mapping_id ])
    else
      source_pr = run.project.issues.pull_requests_only.find_by(github_number: run.source_pull_request_number,
        pr_review_phase: "merged", merged_commit_sha: run.base_commit_sha)
      CloseoutVerifications::Admit.call(source_pr:, merge_commit_sha: run.base_commit_sha) if source_pr
    end
  end
end
