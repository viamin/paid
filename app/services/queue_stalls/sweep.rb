# frozen_string_literal: true

module QueueStalls
  # Bounded sweep that detects non-progressing delivery handoffs and hands
  # each one to the existing recovery services (#4619).
  #
  # The sweep is deliberately small: a bounded number of projects, a bounded
  # number of stalls per invocation, and a bounded number of semantic
  # recoveries. Every assessment is deduplicated by the state digest, so
  # repeated unchanged state is never recovered twice.
  # @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-006
  # @spec QUEUE-DIAG-008 @spec QUEUE-DIAG-012
  class Sweep
    Result = Struct.new(
      :scanned, :detected, :recovered, :blocked, :skipped, :failed, keyword_init: true
    ) do
      def to_h
        { scanned:, detected:, recovered:, blocked:, skipped:, failed: }
      end
    end

    # Bounds for one invocation.
    MAX_PROJECTS = 20
    MAX_STALLS = 50
    MAX_SEMANTIC_RECOVERIES = 2

    def self.call(...)
      new(...).call
    end

    def initialize(account:, project: nil)
      @account = account
      @project = project
    end

    def call
      counters = Hash.new(0)
      projects.each do |current_project|
        counters[:scanned] += 1
        sweep_project(current_project, counters)
      end

      Result.new(
        scanned: counters[:scanned],
        detected: counters[:detected],
        recovered: counters[:recovered],
        blocked: counters[:blocked],
        skipped: counters[:skipped],
        failed: counters[:failed]
      )
    end

    private

    attr_reader :account, :project

    def projects
      @projects ||= begin
        scope = Project.where(account_id: account.id, active: true)
        scope = scope.where(id: project.id) if project
        scope.order(:id).limit(MAX_PROJECTS).to_a
      end
    end

    def sweep_project(current_project, counters)
      candidates = Detector.call(project: current_project)
      remaining = MAX_STALLS - counters[:detected]
      return if remaining <= 0

      candidates = candidates.first(remaining)
      counters[:detected] += candidates.size
      candidates.each do |candidate|
        recover(current_project, candidate, counters)
      end
    end

    def recover(current_project, candidate, counters)
      if candidate.reason_code == "unresolved_delivery" && semantic_recoveries >= MAX_SEMANTIC_RECOVERIES
        counters[:skipped] += 1
        log_skipped(current_project, candidate, "The semantic recovery budget for this sweep is exhausted.")
        return
      end

      outcome = assess(candidate)
      counters[outcome.outcome.to_sym] += 1
      @semantic_recoveries = semantic_recoveries + 1 if candidate.reason_code == "unresolved_delivery"
      log_outcome(current_project, candidate, outcome)
    end

    def assess(candidate)
      issue = Issue.find_by(id: candidate.issue_id)
      return skipped_outcome(candidate, "The issue no longer exists.") if issue.nil?

      blockers = Issues::QueueBlockers.call(issue).blockers
      evidence = Issues::CloseoutEvidence.call(issue)
      digest = StateDigest.call(
        issue: issue,
        reason_code: candidate.reason_code,
        blockers: blockers,
        closeout_evidence: evidence
      )

      Recovery.call(
        account: account,
        candidate: candidate,
        state_digest: digest,
        blockers: blockers,
        closeout_evidence: evidence
      )
    end

    def skipped_outcome(candidate, message)
      Recovery::Outcome.new(
        issue_id: candidate.issue_id,
        reason_code: candidate.reason_code,
        outcome: "skipped",
        message:
      )
    end

    def log_outcome(current_project, candidate, outcome)
      Rails.logger.info(
        message: "queue_stalls.recovery_outcome",
        project_id: current_project.id,
        issue_id: candidate.issue_id,
        reason_code: candidate.reason_code,
        outcome: outcome.outcome,
        detail: outcome.message
      )
    end

    def log_skipped(current_project, candidate, detail)
      Rails.logger.info(
        message: "queue_stalls.recovery_skipped",
        project_id: current_project.id,
        issue_id: candidate.issue_id,
        reason_code: candidate.reason_code,
        detail:
      )
    end

    def semantic_recoveries
      @semantic_recoveries ||= 0
    end
  end
end
