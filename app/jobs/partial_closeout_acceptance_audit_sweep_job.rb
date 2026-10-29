# frozen_string_literal: true

# Revisits closeouts after PR merge, when terminal evidence is available.
# Source-run advancement can finish before merge and correctly refuse admission.
# @spec PARTIAL-CLOSEOUT-037
class PartialCloseoutAcceptanceAuditSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  MAX_PER_PROJECT = 3

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "partial_closeout_acceptance_audit_sweep"
  )

  def perform
    processed = 0
    enqueued = 0

    Project.active.where(auto_pick_enabled: true).includes(:account, :created_by).find_each do |project|
      next unless Issues::AutoPickProjectGate.call(project)

      count = sweep_project(project)
      processed += 1
      enqueued += count
    rescue StandardError => error
      Rails.logger.error(message: "partial_closeout.audit_sweep_project_failed",
        project_id: project.id, error_class: error.class.name, error: error.message)
    end

    Rails.logger.info(message: "partial_closeout.audit_sweep_completed",
      processed_projects: processed, enqueued_runs: enqueued)
  end

  private

  def sweep_project(project)
    enqueued = 0
    Issues::StalledCloseouts.call([ project ]).each do |pair|
      outcome = PartialCloseouts::AutoAudit.call(issue: pair.issue)
      enqueued += 1 if outcome.scheduled?
      break if enqueued >= MAX_PER_PROJECT
    end
    enqueued
  end
end
