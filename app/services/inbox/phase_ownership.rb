# frozen_string_literal: true

# RDR-077 §5: phase ownership for Inbox requests.
#
# Ownership is assigned when the request is produced and persisted per stable
# request key. Legacy requests are classified from existing run, issue, and
# request-producer evidence; requests whose evidence does not resolve to a
# phase stay visible with an explicit classification gap rather than being
# hidden or granted execution authority.
#
# @spec INBOX-PHASE-RELEVANCE-001 @spec AUTOMATION-PHASES-017
module Inbox
  module PhaseOwnership
    CLASSIFIED = "classified"
    UNKNOWN = "unknown"
    PLATFORM = "platform"

    # Ownership decided by request kind alone.
    KIND_PHASES = {
      Inbox::Queue::CLARIFYING_QUESTIONS_KIND => Automation::Phases::ISSUE_PREPARATION,
      Inbox::Queue::PLAN_REVIEW_KIND => Automation::Phases::ISSUE_PREPARATION,
      Inbox::Queue::MERGE_APPROVAL_KIND => Automation::Phases::MERGE,
      Inbox::Queue::ESCALATED_PR_KIND => Automation::Phases::CODING,
      Inbox::Queue::RETRY_LIMITED_KIND => Automation::Phases::CODING,
      Inbox::Queue::INTENT_CONFORMANCE_KIND => Automation::Phases::CODING,
      Inbox::Queue::CHANGE_INTENT_DRAFT_KIND => Automation::Phases::CODING,
      Inbox::Queue::PARTIAL_CLOSEOUT_KIND => Automation::Phases::CODING,
      Inbox::Queue::TEST_REVIEW_PENDING_KIND => Automation::Phases::CODING,
      Inbox::Queue::TRACEABILITY_GAP_KIND => Automation::Phases::CODING,
      Inbox::Queue::ACTION_REQUIRED_KIND => Automation::Phases::OPERATIONS,
      Inbox::Queue::FEATURE_DECISION_KIND => Automation::Phases::DISCOVERY,
      Inbox::Queue::PROJECT_SETUP_PENDING_KIND => Automation::Phases::DISCOVERY
    }.freeze

    # manual_review has several causes; the stop reason and the latest run goal
    # say which phase owns the stop.
    Ownership = Struct.new(:request_key, :entry_kind, :record_id, :project, :responsible_phase,
      :classification_state, :origin_kind, :origin_id, :stored, keyword_init: true) do
      def platform?
        classification_state == PLATFORM
      end

      def unknown?
        classification_state == UNKNOWN
      end

      def phase_owned?
        responsible_phase.present?
      end

      def phase_label
        Automation::Phases.label(responsible_phase)
      end
    end

    module_function

    # Assign ownership at production time. Safe to call repeatedly for the same
    # request key: an existing explicit assignment wins.
    # @spec INBOX-PHASE-RELEVANCE-001
    def record!(entry, phase:, origin_kind: nil, origin_id: nil)
      persist(explicit_ownership(entry, phase, origin_kind, origin_id))
    end

    # Issue-backed lanes record ownership the moment the request is produced,
    # without building a queue entry first.
    def record_issue_request!(issue:, kind:, phase: nil)
      resolved_phase = phase.presence || phase_for_issue_kind(kind, issue)
      persist(
        Ownership.new(
          request_key: "#{kind}:#{issue.id}",
          entry_kind: kind,
          record_id: issue.id,
          project: issue.project,
          responsible_phase: resolved_phase,
          classification_state: resolved_phase ? CLASSIFIED : UNKNOWN,
          origin_kind: issue.is_pull_request? ? "pull_request" : "issue",
          origin_id: issue.id
        )
      )
    end

    # Ownership for any entry: stored first, classified from evidence otherwise.
    def for_entry(entry)
      stored = InboxRequestOwnership.find_by(request_key: entry.id)
      return ownership_from_record(stored) if stored

      derive(entry)
    end

    # Queue construction resolves stored ownership and manual-review evidence
    # in batches, avoiding one ownership and latest-run query per entry.
    def for_entries(entries)
      return {} if entries.empty?

      stored_by_key = InboxRequestOwnership.includes(:project).where(request_key: entries.map(&:id)).index_by(&:request_key)
      latest_runs = latest_runs_by_issue_id(entries)

      entries.to_h do |entry|
        stored = stored_by_key[entry.id]
        ownership = stored ? ownership_from_record(stored) : derive(entry, latest_runs:)
        [ entry.id, ownership ]
      end
    end

    def persist(ownership)
      InboxRequestOwnership.upsert(
        {
          request_key: ownership.request_key,
          entry_kind: ownership.entry_kind,
          record_id: ownership.record_id,
          project_id: ownership.project&.id,
          responsible_phase: ownership.responsible_phase,
          classification_state: ownership.classification_state,
          origin_kind: ownership.origin_kind,
          origin_id: ownership.origin_id,
          classified_at: Time.current
        },
        unique_by: :index_inbox_request_ownerships_on_request_key
      )
      ownership
    end

    def ownership_from_record(record)
      Ownership.new(
        request_key: record.request_key,
        entry_kind: record.entry_kind,
        record_id: record.record_id,
        project: record.project,
        responsible_phase: record.responsible_phase,
        classification_state: record.classification_state,
        origin_kind: record.origin_kind,
        origin_id: record.origin_id,
        stored: true
      )
    end

    def explicit_ownership(entry, phase, origin_kind, origin_id)
      resolved_phase = phase.to_s.presence
      Ownership.new(
        request_key: entry.id,
        entry_kind: entry.kind,
        record_id: record_id_for(entry),
        project: entry.project,
        responsible_phase: resolved_phase,
        classification_state: resolved_phase ? CLASSIFIED : UNKNOWN,
        origin_kind: origin_kind || origin_kind_for(entry),
        origin_id: origin_id || origin_id_for(entry)
      )
    end

    # Classification from producer evidence. Insufficient evidence leaves the
    # ownership unknown instead of guessing a phase.
    def derive(entry, origin_kind = nil, origin_id = nil, latest_runs: nil)
      return platform_ownership(entry, origin_kind, origin_id) if platform_request?(entry)

      phase = phase_for(entry, latest_runs:)

      Ownership.new(
        request_key: entry.id,
        entry_kind: entry.kind,
        record_id: record_id_for(entry),
        project: entry.project,
        responsible_phase: phase,
        classification_state: phase ? CLASSIFIED : UNKNOWN,
        origin_kind: origin_kind || origin_kind_for(entry),
        origin_id: origin_id || origin_id_for(entry)
      )
    end

    def platform_ownership(entry, origin_kind, origin_id)
      Ownership.new(
        request_key: entry.id,
        entry_kind: entry.kind,
        record_id: record_id_for(entry),
        project: entry.project,
        responsible_phase: nil,
        classification_state: PLATFORM,
        origin_kind: origin_kind || origin_kind_for(entry),
        origin_id: origin_id || origin_id_for(entry)
      )
    end

    def phase_for(entry, latest_runs: nil)
      return KIND_PHASES[entry.kind] unless entry.kind == Inbox::Queue::MANUAL_REVIEW_KIND

      manual_review_phase(entry, latest_runs:)
    end

    def manual_review_phase(entry, latest_runs: nil)
      phase_for_manual_review_issue(entry.issue, latest_runs:)
    end

    # manual_review has several causes; the stop reason and the latest run goal
    # say which phase owns the stop.
    def phase_for_manual_review_issue(issue, latest_runs: nil)
      return nil unless issue
      if IssueEnhancements::StopForManualReview.enhancement_reason?(issue.manual_review_reason)
        return Automation::Phases::ISSUE_PREPARATION
      end

      latest_run = latest_runs ? latest_runs[issue.id] : issue.agent_runs.order(created_at: :desc, id: :desc).first
      return Automation::Phases::ISSUE_PREPARATION if latest_run&.enhance_issue_goal?

      Automation::Phases::CODING
    end

    def phase_for_issue_kind(kind, issue)
      return phase_for_manual_review_issue(issue) if kind == Inbox::Queue::MANUAL_REVIEW_KIND

      KIND_PHASES[kind.to_s]
    end

    def latest_runs_by_issue_id(entries)
      issue_ids = entries.filter_map { |entry| entry.issue&.id if entry.manual_review? }.uniq
      return {} if issue_ids.empty?

      AgentRun.where(issue_id: issue_ids)
        .select("DISTINCT ON (issue_id) agent_runs.*")
        .order(:issue_id, created_at: :desc, id: :desc)
        .index_by(&:issue_id)
    end

    # Paid's platform health, credential, and safety requests are
    # project-independent: they carry no project phase, stay visible regardless
    # of a project's Operations phase, and never gain execution authority.
    # A request with no project at all, a notification about a runner's
    # credentials, or an account-level notification with no subject is one.
    # Unverifiable reconciliation coverage is an access problem, not coding
    # work, so a disabled coding phase can never hide it.
    # @spec INBOX-PHASE-RELEVANCE-001 @spec OPERATOR-INBOX-020
    def platform_request?(entry)
      return true if entry.project.nil?
      return true if unverifiable_coverage_request?(entry)
      return false unless entry.record.is_a?(Notification)

      subject = entry.record.subject
      subject.nil? || subject.is_a?(Runner) || subject.is_a?(Account)
    end

    def unverifiable_coverage_request?(entry)
      entry.traceability_gap? && entry.record.try(:unverifiable?)
    end

    def record_id_for(entry)
      entry.record.try(:id).to_i
    end

    def origin_kind_for(entry)
      return "pull_request" if entry.record.is_a?(Issue) && entry.record.is_pull_request?
      return "issue" if entry.issue
      return "project" if entry.record.is_a?(Project)

      entry.record.class.name&.underscore || entry.kind
    end

    def origin_id_for(entry)
      entry.issue&.id || entry.record.try(:id)
    end
  end
end
