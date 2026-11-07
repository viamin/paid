# frozen_string_literal: true

# Periodic backstop for eligible issues that did not receive a reactive enqueue.
# Continuation arguments hold immutable-ID cursors, so live scope changes cannot
# shift an offset and skip a candidate.
class AutoPickEligibilitySweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  SweepResult = Struct.new(:cursor, :issues, :enqueued, keyword_init: true)

  queue_as :maintenance

  PROJECT_PAGE_SIZE = 10
  ISSUE_PAGE_SIZE = 100
  MAX_PROJECT_PAGE_ATTEMPTS = 2

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "auto_pick_eligibility_sweep"
  )

  # @spec EAGER-QUEUE-017
  def perform(after_project_id: nil, through_project_id: nil, page_after_project_id: nil, pending_projects: {})
    started_at = monotonic_clock
    allocated_before = GC.stat(:total_allocated_objects)
    through_project_id ||= eligible_projects.maximum(:id)
    return unless through_project_id

    page = pending_projects.presence || fresh_project_page(after_project_id, through_project_id)
    page_after_project_id ||= cursor_value(page.values.last, :project_id) if page.present?
    results = sweep_page(page)
    log_page(started_at, allocated_before, page.size, results)

    if results.any? { |result| result.cursor }
      self.class.perform_later(
        after_project_id: page_after_project_id,
        through_project_id:,
        page_after_project_id:,
        pending_projects: results.filter_map(&:cursor).index_by { |cursor| cursor_value(cursor, :project_id).to_s }
      )
      return
    end

    enqueue_next_page(page_after_project_id, through_project_id) if page.present?
  end

  private

  def eligible_projects
    Project.active.where(auto_pick_enabled: true).includes(:account, :created_by)
  end

  def fresh_project_page(after_project_id, through_project_id)
    project_page(after_project_id, through_project_id).index_with do |project|
      { project_id: project.id, after_issue_id: nil, through_issue_id: nil }
    end
  end

  def project_page(after_project_id, through_project_id)
    eligible_projects
      .where("projects.id > ? AND projects.id <= ?", after_project_id.to_i, through_project_id)
      .order(:id)
      .limit(PROJECT_PAGE_SIZE)
      .to_a
  end

  def sweep_page(page)
    projects = eligible_projects.where(id: page.values.map { |cursor| cursor_value(cursor, :project_id) }).index_by(&:id)
    owners = batch_resolve_owners(projects.values)
    page.values.map { |cursor| sweep_project(projects[cursor_value(cursor, :project_id)], cursor, owners) }
  end

  def sweep_project(project, cursor, owners)
    return SweepResult.new(issues: 0, enqueued: 0) unless project
    return SweepResult.new(issues: 0, enqueued: 0) unless Issues::AutoPickProjectGate.call(project, owner: owners[project.id])

    through_issue_id = cursor_value(cursor, :through_issue_id) || Issue.where(project_id: project.id).maximum(:id)
    page = Issues::BulkEnqueueEligible.call(
      project:,
      skip_project_gate: true,
      after_issue_id: cursor_value(cursor, :after_issue_id),
      through_issue_id:,
      page_size: ISSUE_PAGE_SIZE
    )
    SweepResult.new(
      cursor: next_cursor(project, page, through_issue_id),
      issues: page.candidate_count,
      enqueued: page.runs.count(&:previously_new_record?)
    )
  rescue StandardError => error
    attempts = cursor_value(cursor, :attempts).to_i + 1
    Rails.logger.error(
      message: "auto_pick_eligibility_sweep.project_failed",
      project_id: project.id,
      attempt: attempts,
      retry_exhausted: attempts >= MAX_PROJECT_PAGE_ATTEMPTS,
      error_class: error.class.name,
      error: error.message
    )
    retry_cursor = cursor.merge(attempts:) if attempts < MAX_PROJECT_PAGE_ATTEMPTS
    SweepResult.new(cursor: retry_cursor, issues: 0, enqueued: 0)
  end

  def next_cursor(project, page, through_issue_id)
    return unless page.more?

    { project_id: project.id, after_issue_id: page.last_issue_id, through_issue_id: }
  end

  def enqueue_next_page(after_project_id, through_project_id)
    return if project_page(after_project_id, through_project_id).empty?

    self.class.perform_later(after_project_id:, through_project_id:)
  end

  def batch_resolve_owners(projects)
    fallback_by_account = Account.batch_fallback_owner_ids(projects.filter_map(&:account_id).uniq)
    owner_ids = projects.filter_map { |project| project.created_by_id || fallback_by_account[project.account_id] }.uniq
    users_by_id = User.where(id: owner_ids).index_by(&:id)
    projects.to_h do |project|
      owner_id = project.created_by_id || fallback_by_account[project.account_id]
      [ project.id, users_by_id[owner_id] ]
    end
  end

  def cursor_value(cursor, key)
    cursor[key] || cursor[key.to_s]
  end

  def log_page(started_at, allocated_before, project_count, results)
    Rails.logger.info(
      message: "auto_pick_eligibility_sweep.page_completed",
      project_count:,
      issue_count: results.sum(&:issues),
      enqueued_count: results.sum(&:enqueued),
      duration_ms: elapsed_ms(started_at),
      allocations: GC.stat(:total_allocated_objects) - allocated_before,
      peak_rss_kb: peak_rss_kb
    )
  end

  def monotonic_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def elapsed_ms(started_at)
    ((monotonic_clock - started_at) * 1000).round
  end

  def peak_rss_kb
    File.foreach("/proc/self/status") do |line|
      return line.split.last.to_i if line.start_with?("VmHWM:")
    end
    nil
  rescue Errno::ENOENT
    nil
  end
end
