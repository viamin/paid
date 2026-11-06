# frozen_string_literal: true

# Revisits closeouts after PR merge, when terminal evidence is available.
# Source-run advancement can finish before merge and correctly refuse admission.
# @spec PARTIAL-CLOSEOUT-037
class PartialCloseoutAcceptanceAuditSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  MAX_PER_PROJECT = 3
  ISSUE_BATCH_SIZE = 50

  good_job_control_concurrency_with(
    enqueue_limit: 2,
    perform_limit: 1,
    key: "partial_closeout_acceptance_audit_sweep"
  )

  # @spec PARTIAL-CLOSEOUT-041
  def perform(after_project_id: nil, project_id: nil, after_issue_id: nil,
    through_project_id: nil, through_issue_id: nil, enqueued_for_project: 0)
    through_project_id ||= eligible_projects.maximum(:id)
    return unless through_project_id

    project = project_id ? eligible_projects.find_by(id: project_id) : next_project(after_project_id, through_project_id)
    if project.nil? && project_id
      enqueue_next_project(project_id, through_project_id)
      return
    end
    return unless project

    if Issues::AutoPickProjectGate.call(project)
      through_issue_id ||= Issues::StalledCloseouts.candidates_for(project).maximum(:id)
      if through_issue_id
        count, cursor, more = sweep_project_page(project, after_issue_id:, through_issue_id:,
          enqueued_for_project:)
        if more
          self.class.perform_later(project_id: project.id, after_issue_id: cursor,
            through_project_id:, through_issue_id:, enqueued_for_project: enqueued_for_project + count)
          return
        end
      end
    end

    enqueue_next_project(project.id, through_project_id)
  rescue StandardError => error
    if project
      Rails.logger.error(message: "partial_closeout.audit_sweep_project_failed",
        project_id: project.id, error_class: error.class.name, error: error.message)
      enqueue_next_project(project.id, through_project_id)
    else
      raise
    end
  end

  private

  def eligible_projects
    Project.active.where(auto_pick_enabled: true).includes(:account, :created_by)
  end

  def next_project(after_project_id, through_project_id)
    eligible_projects.where("projects.id > ? AND projects.id <= ?", after_project_id.to_i, through_project_id)
      .order(:id).first
  end

  def enqueue_next_project(project_id, through_project_id)
    return unless next_project(project_id, through_project_id)

    self.class.perform_later(after_project_id: project_id, through_project_id:)
  end

  def sweep_project_page(project, after_issue_id:, through_issue_id:, enqueued_for_project:)
    candidates = Issues::StalledCloseouts.candidates_for(project)
      .where("issues.id > ? AND issues.id <= ?", after_issue_id.to_i, through_issue_id)
      .order(:id).limit(ISSUE_BATCH_SIZE).to_a
    enqueued = 0
    Issues::StalledCloseouts.pairs_for(project, candidates:).each do |pair|
      outcome = PartialCloseouts::AutoAudit.call(issue: pair.issue)
      enqueued += 1 if outcome.scheduled?
      break if enqueued_for_project + enqueued >= MAX_PER_PROJECT
    rescue StandardError => error
      Rails.logger.error(message: "partial_closeout.audit_sweep_project_failed",
        project_id: project.id, error_class: error.class.name, error: error.message)
    end
    Rails.logger.info(message: "partial_closeout.audit_sweep_completed",
      project_id: project.id, candidates_scanned: candidates.size, enqueued_runs: enqueued)
    [ enqueued, candidates.last&.id, candidates.size == ISSUE_BATCH_SIZE &&
      enqueued_for_project + enqueued < MAX_PER_PROJECT ]
  end
end
