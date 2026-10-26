# frozen_string_literal: true

module Dashboard
  # Explains the visible queue: one diagnostic state, the counts that keep
  # candidate eligibility, queued work, running work and held work apart,
  # and the issue-level blocker provenance behind the explanation (#4619).
  #
  # Read-only by construction: it never performs an LLM call, never executes
  # repository code, and never mutates GitHub or the database. The canonical
  # candidate scope (`DefaultCandidateSource`) and the canonical scheduler
  # scope (`AgentRun.schedulable_queued_with_priority`) are the only sources
  # of truth, so the explanation can never disagree with the scheduler.
  # @spec QUEUE-DIAG-001 @spec QUEUE-DIAG-002 @spec QUEUE-DIAG-003
  # @spec QUEUE-DIAG-009 @spec QUEUE-DIAG-010 @spec QUEUE-DIAG-011
  class QueueDiagnosis
    STATES = %i[healthy runnable_not_seeded blocked paused unknown].freeze
    CACHE_TTL = 10.seconds
    # Bound the per-issue provenance work: the counts cover every held issue,
    # the inspectable detail covers the oldest ones.
    MAX_DETAILED_ISSUES = 20
    # A project whose issue sync has not completed for this long cannot be
    # read as "no work"; its coverage is unknown instead.
    SYNC_STALE_AGE = 6.hours

    Counts = Struct.new(:eligible, :queued, :running, :blocked, :paused, :held, keyword_init: true) do
      def to_h
        { eligible:, queued:, running:, blocked:, paused:, held: }
      end
    end

    ProjectDiagnosis = Struct.new(
      :project, :coverage, :coverage_reason, :counts, :blockers, keyword_init: true
    ) do
      def coverage_unknown? = coverage == :unknown
    end

    Result = Struct.new(
      :state, :counts, :projects, :blockers, :generated_at, :error, :recovery, keyword_init: true
    ) do
      def unknown? = state == :unknown
      def failed? = error.present?
      def state_label = QueueDiagnosis.state_label(state)
      def next_actions = QueueDiagnosis.next_actions(state)
    end

    STATE_LABELS = {
      healthy: "Healthy — no waiting backlog",
      runnable_not_seeded: "Runnable work was never queued",
      blocked: "Blocked by dependency or decision holds",
      paused: "Paused by resource or policy",
      unknown: "Diagnosis unavailable — coverage unknown"
    }.freeze

    NEXT_ACTIONS = {
      healthy: [],
      runnable_not_seeded: [ "Seed the eligible candidates so the scheduler can dispatch them." ],
      blocked: [ "Resolve the blockers listed below, or open the Inbox lane that owns the decision." ],
      paused: [ "Resume the paused project or scheduler to admit automatic work." ],
      unknown: [ "Retry the diagnosis, and re-sync issues for the projects with unknown coverage." ]
    }.freeze

    def self.call(...)
      new(...).call
    end

    def self.state_label(state)
      STATE_LABELS.fetch(state, STATE_LABELS[:unknown])
    end

    def self.next_actions(state)
      NEXT_ACTIONS.fetch(state, NEXT_ACTIONS[:unknown])
    end

    def initialize(user:)
      @user = user
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build }
    rescue StandardError => error
      Rails.logger.error(
        message: "dashboard.queue_diagnosis.failed",
        error_class: error.class.name,
        error: error.message
      )
      failure_result(error)
    end

    private

    attr_reader :user

    def build
      projects = visible_projects
      return empty_result if projects.empty?

      diagnoses = projects.map { |project| diagnose_project(project) }
      counts = aggregate_counts(diagnoses)
      Result.new(
        state: state_for(counts, diagnoses),
        counts: counts,
        projects: diagnoses,
        blockers: diagnoses.flat_map { |diagnosis| diagnosis.blockers },
        generated_at: Time.current,
        error: nil,
        recovery: nil
      )
    end

    # The projects whose automatic work this user may see. The queue preview
    # owns the visibility rule; the diagnosis reuses it so the rendered queue
    # and its explanation always describe the same projects.
    # @spec QUEUE-DIAG-011 @spec QUEUE-DIAG-012
    def visible_projects
      @visible_projects ||= Project
        .where(id: Dashboard::QueuePreview.visible_project_ids(user))
        .includes(:account, :created_by)
        .order(:id)
        .to_a
    end

    # @spec QUEUE-DIAG-001 @spec QUEUE-DIAG-002
    def diagnose_project(project)
      coverage, coverage_reason = coverage_for(project)
      runs = run_counts_for(project)

      return automatic_project_diagnosis(project, coverage, coverage_reason, runs) if automatic_work?(project)
      return paused_project_diagnosis(project, coverage, coverage_reason, runs) if project_paused?(project)

      inactive_project_diagnosis(project, coverage, coverage_reason, runs)
    end

    def automatic_project_diagnosis(project, coverage, coverage_reason, runs)
      eligible_ids = eligible_issue_ids(project)
      open_ids = open_issue_ids(project)
      covered_ids = covered_issue_ids(project)
      paused_run_ids = paused_run_issue_ids(project)
      held_ids = open_ids - eligible_ids - covered_ids - paused_run_ids
      paused_issue_ids = issue_paused_ids(project, held_ids)

      ProjectDiagnosis.new(
        project: project,
        coverage: coverage,
        coverage_reason: coverage_reason,
        counts: Counts.new(
          eligible: eligible_ids.size,
          queued: runs[:queued],
          running: runs[:running],
          blocked: held_ids.size - paused_issue_ids.size,
          paused: paused_issue_ids.size + paused_run_ids.size,
          held: held_ids.size + paused_run_ids.size
        ),
        blockers: blockers_for(project, held_ids | paused_run_ids)
      )
    end

    # A paused project explains every open issue it holds: the pause, not the
    # issue, is what stops the work.
    def paused_project_diagnosis(project, coverage, coverage_reason, runs)
      paused_count = open_issue_ids(project).size

      ProjectDiagnosis.new(
        project: project,
        coverage: coverage,
        coverage_reason: coverage_reason,
        counts: Counts.new(
          eligible: 0,
          queued: runs[:queued],
          running: runs[:running],
          blocked: 0,
          paused: paused_count,
          held: paused_count
        ),
        blockers: []
      )
    end

    # A project that does not run automatic work (auto-pick off) contributes
    # its queued and running work to the explanation, but its issues are not
    # classified as blocked: there is no backlog to explain.
    def inactive_project_diagnosis(project, coverage, coverage_reason, runs)
      ProjectDiagnosis.new(
        project: project,
        coverage: coverage,
        coverage_reason: coverage_reason,
        counts: Counts.new(eligible: 0, queued: runs[:queued], running: runs[:running], blocked: 0, paused: 0, held: 0),
        blockers: []
      )
    end

    def automatic_work?(project)
      project.auto_pick_enabled? && !project_paused?(project)
    end

    def project_paused?(project)
      project.paused? ||
        project.quality_paused_at.present? ||
        project.scheduler_paused_at.present? ||
        project.account&.scheduler_paused?
    end

    # @spec QUEUE-DIAG-001
    def state_for(counts, diagnoses)
      return :unknown if diagnoses.any?(&:coverage_unknown?)
      return :runnable_not_seeded if counts.eligible.positive?
      return :healthy if counts.queued.positive? || counts.running.positive?
      return :blocked if counts.blocked.positive?
      return :paused if counts.paused.positive?

      :healthy
    end

    def aggregate_counts(diagnoses)
      diagnoses.reduce(Counts.new(eligible: 0, queued: 0, running: 0, blocked: 0, paused: 0, held: 0)) do |total, diagnosis|
        Counts.new(
          eligible: total.eligible + diagnosis.counts.eligible,
          queued: total.queued + diagnosis.counts.queued,
          running: total.running + diagnosis.counts.running,
          blocked: total.blocked + diagnosis.counts.blocked,
          paused: total.paused + diagnosis.counts.paused,
          held: total.held + diagnosis.counts.held
        )
      end
    end

    # The queued runs come from the canonical scheduler scope, the same scope
    # the queue preview renders, so the explanation and the rendered queue
    # describe one backend queue.
    # @spec QUEUE-DIAG-002 @spec QUEUE-DIAG-010
    def run_counts_for(project)
      @run_counts ||= {}
      @run_counts[project.id] ||= begin
        queued = queued_runs_by_project.fetch(project.id, 0)
        running = running_counts.fetch(project.id, 0)
        { queued: queued, running: running }
      end
    end

    def queued_runs_by_project
      @queued_runs_by_project ||= queued_runs.group_by(&:project_id).transform_values(&:size)
    end

    def queued_runs
      @queued_runs ||= queue_snapshot
    end

    def queue_snapshot
      @queue_snapshot ||= Dashboard::QueuePreview.new(user: user).snapshot
    end

    def running_counts
      @running_counts ||= AgentRun
        .running
        .where(project_id: visible_projects.map(&:id))
        .group(:project_id)
        .count
    end

    def eligible_issue_ids(project)
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_scope(project)
        .pluck(:id)
        .to_set
    end

    def open_issue_ids(project)
      project.issues.where(github_state: "open", is_pull_request: false).pluck(:id).to_set
    end

    def covered_issue_ids(project)
      AgentRun
        .where(project_id: project.id, status: %w[queued running])
        .where.not(issue_id: nil)
        .pluck(:issue_id)
        .to_set
    end

    def paused_run_issue_ids(project)
      AgentRun
        .where(project_id: project.id, status: "paused")
        .where.not(issue_id: nil)
        .pluck(:issue_id)
        .to_set
    end

    def issue_paused_ids(project, held_ids)
      return Set.new if held_ids.empty?

      project.issues.where(id: held_ids.to_a, paused: true).pluck(:id).to_set
    end

    # @spec QUEUE-DIAG-003
    def blockers_for(project, issue_ids)
      return [] if issue_ids.empty?

      issues = project.issues.where(id: issue_ids.to_a).order(:github_number).limit(MAX_DETAILED_ISSUES).to_a
      return [] if issues.empty?

      evidence = Issues::CloseoutEvidence.results_for(issues)
      assessments = latest_assessments(issues)
      reset_at = analysis_backoff_reset_at(project)

      issues.map do |issue|
        result = Issues::QueueBlockers.call(
          issue,
          closeout_evidence: evidence[issue.id],
          analysis_backoff_reset_at: reset_at
        )
        BlockerDetail.new(
          issue: issue,
          blockers: result.blockers,
          assessment: assessments[issue.id]
        )
      end
    end

    def latest_assessments(issues)
      QueueStallAssessment
        .latest_per_issue(issues.map(&:id))
        .index_by(&:issue_id)
    end

    def analysis_backoff_reset_at(project)
      Issues::IssueAnalysisBackoffResetContext.call(project: project)
    end

    # A project whose issue sync never completed, or has not completed for a
    # long time, cannot be read as "no work": its coverage is unknown.
    # @spec QUEUE-DIAG-009
    def coverage_for(project)
      watermark = project.last_issue_sync_at
      return [ :known, nil ] if watermark.present? && watermark > SYNC_STALE_AGE.ago
      return [ :known, nil ] if watermark.blank? && project.created_at > SYNC_STALE_AGE.ago

      reason = watermark.blank? ? "Issues have never been synced for this project." : "The issue sync is older than #{SYNC_STALE_AGE.inspect}."
      [ :unknown, reason ]
    end

    def empty_result
      Result.new(
        state: :healthy,
        counts: Counts.new(eligible: 0, queued: 0, running: 0, blocked: 0, paused: 0, held: 0),
        projects: [],
        blockers: [],
        generated_at: Time.current,
        error: nil,
        recovery: nil
      )
    end

    def failure_result(error)
      Result.new(
        state: :unknown,
        counts: Counts.new(eligible: 0, queued: 0, running: 0, blocked: 0, paused: 0, held: 0),
        projects: [],
        blockers: [],
        generated_at: Time.current,
        error: "#{error.class}: #{error.message}",
        recovery: "The queue diagnosis could not be computed. Retry it; a failed diagnosis is never proof that no work exists."
      )
    end

    def cache_key
      "dashboard/queue_diagnosis/#{user.account_id}/#{user.id}/" \
        "#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end

    # One inspected issue with its blocker provenance and the last successful
    # stall assessment recorded for it.
    BlockerDetail = Struct.new(:issue, :blockers, :assessment, keyword_init: true) do
      def human_decision? = blockers.any? { |blocker| Issues::QueueBlockers::HUMAN_DECISION_CODES.include?(blocker.code) }
      def paused? = blockers.any? && blockers.all? { |blocker| Issues::QueueBlockers::PAUSE_CODES.include?(blocker.code) }
      def owners = blockers.filter_map(&:owner).uniq
    end
  end
end
