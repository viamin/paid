# frozen_string_literal: true

class ScheduledMutationSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency
  include Containers::QualityHooks

  queue_as :metrics

  good_job_control_concurrency_with(total_limit: 1)

  def perform(project_id: nil, sweep_date: Date.current.iso8601, attempted_project_ids: [])
    @sweep_date = Date.iso8601(sweep_date)
    attempted_project_ids = attempted_project_ids.map(&:to_i)

    project = if project_id
      eligible_project(project_id, excluding_project_ids: attempted_project_ids)
    else
      next_project(excluding_project_ids: attempted_project_ids)
    end
    return unless project

    run_project_sweep(project)
    enqueue_next_project(attempted_project_ids: attempted_project_ids | [ project.id ])
  end

  private

  attr_reader :sweep_date

  def eligible_projects
    Project
      .joins(:pre_commit_requirements)
      .merge(PreCommitRequirement.enabled.where(check_type: "mutation_test"))
      .distinct
      .order(:id)
  end

  def eligible_project(project_id, excluding_project_ids: [])
    project = eligible_projects.find_by(id: project_id)
    return unless project
    return if excluding_project_ids.include?(project.id)
    return unless ruby_project?(project)
    return if swept_on_date?(project)

    project
  end

  def next_project(excluding_project_ids: [])
    eligible_projects.find do |project|
      !excluding_project_ids.include?(project.id) && ruby_project?(project) && !swept_on_date?(project)
    end
  end

  def ruby_project?(project)
    Prompts::LanguageCommands.test_languages(project).include?("ruby")
  end

  def swept_on_date?(project)
    QualityMetric.by_project(project.id)
      .scheduled_mutation_sweep
      .where(created_at: sweep_date.all_day)
      .exists?
  end

  def run_project_sweep(project)
    MutationSweeps::Run.call(project:, sweep_date:)
  rescue StandardError => e
    Rails.logger.warn(
      message: "scheduled_mutation_sweep.project_failed",
      project_id: project.id,
      error_class: e.class.name,
      error: e.message,
      sweep_date: sweep_date.iso8601
    )
  end

  def enqueue_next_project(attempted_project_ids:)
    if next_project(excluding_project_ids: attempted_project_ids)
      self.class.perform_later(sweep_date: sweep_date.iso8601, attempted_project_ids:)
    end
  end
end
