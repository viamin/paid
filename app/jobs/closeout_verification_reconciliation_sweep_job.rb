# frozen_string_literal: true

# Bounded recovery for merge observations that arrived while enrollment was
# disabled or whose webhook delivery was missed.
class CloseoutVerificationReconciliationSweepJob < ApplicationJob
  queue_as :maintenance

  PROJECT_BATCH_SIZE = 20
  PULL_REQUEST_BATCH_SIZE = 100

  # @spec STAGED-CLOSEOUT-ADOPTION-009
  def perform(after_project_id: nil, through_project_id: nil, project_id: nil, after_pull_request_id: nil)
    return reconcile(Project.active.find_by(id: project_id), after_pull_request_id:) if project_id

    through_project_id ||= Project.active.maximum(:id)
    return unless through_project_id

    projects = Project.active.where("id > ? AND id <= ?", after_project_id.to_i, through_project_id).order(:id).limit(PROJECT_BATCH_SIZE)
    projects.each { |project| reconcile(project) }
    self.class.perform_later(after_project_id: projects.last.id, through_project_id:) if projects.size == PROJECT_BATCH_SIZE
  end

  private

  def reconcile(project, after_pull_request_id: nil)
    return unless project

    scope = project.issues.pull_requests_only.where(pr_review_phase: "merged").where.not(merged_commit_sha: nil)
    scope = scope.where("issues.id > ?", after_pull_request_id) if after_pull_request_id
    source_prs = scope.order(:id).limit(PULL_REQUEST_BATCH_SIZE).to_a
    source_prs.each do |source_pr|
      CloseoutVerifications::Admit.call(source_pr:, merge_commit_sha: source_pr.merged_commit_sha)
    end
    enqueue_pull_request_continuation(project, source_prs)
  end

  def enqueue_pull_request_continuation(project, source_prs)
    return unless source_prs.size == PULL_REQUEST_BATCH_SIZE

    self.class.perform_later(project_id: project.id, after_pull_request_id: source_prs.last.id)
  end
end
