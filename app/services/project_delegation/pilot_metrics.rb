# frozen_string_literal: true

module ProjectDelegation
  # Revision-bound pilot ledger and measurement contract for RDR-080. The
  # existing Inbox history table is append-only per decision and already has
  # tenant RLS, so pilot facts stay in that same evidence boundary.
  # @spec PROJECT-DELEGATION-007
  class PilotMetrics
    EVENT_TYPES = %w[
      human_decision
      issue_started
      issue_completed
      decision_reversed
      security_breach
      tenant_breach
      trust_breach
      evidence_missing
    ].freeze
    MIN_COMPLETED_ISSUES = 30
    OBSERVATION_PERIOD = 14.days

    Result = Data.define(:available, :reason, :sample_count, :observed_days, :metrics) do
      def available? = available
      def to_h = { available:, reason:, sample_count:, observed_days:, metrics: }
    end

    def self.record(project:, event_type:, event_key:, issue: nil, posture:, policy_signature:,
      intent_revision: nil, acceptance_revision: nil, evidence_revision: nil, occurred_at: Time.current,
      decision_started_at: nil, decision_resolved_at: nil, evidence_status: "available", baseline: false,
      material: false, metadata: {})
      raise ArgumentError, "unknown pilot metric event" unless EVENT_TYPES.include?(event_type.to_s)

      subject_key = issue ? "issue:#{issue.id}" : "project:#{project.id}"
      InboxHistoryEvent.find_or_create_by!(account: project.account, subject_key:, event_key:) do |event|
        event.assign_attributes(project:, occurred_at:, actor_label: "Paid", source: "project_delegation_pilot",
          result: event_type, revision: posture.revision.to_s, metadata: {
          "event_type" => event_type.to_s,
          "posture_level" => posture.level,
          "posture_revision" => posture.revision,
          "policy_signature" => policy_signature,
          "intent_revision" => intent_revision,
          "acceptance_revision" => acceptance_revision,
          "evidence_revision" => evidence_revision,
          "evidence_status" => evidence_status,
          "baseline" => baseline,
          "material" => material,
          "decision_started_at" => decision_started_at&.iso8601,
          "decision_resolved_at" => decision_resolved_at&.iso8601
          }.merge(metadata.to_h.transform_keys(&:to_s)).compact)
      end
    end

    def self.call(project:, now: Time.current)
      new(project:, now:).call
    end

    def initialize(project:, now:)
      @project = project
      @now = now
    end

    def call
      rows = InboxHistoryEvent.where(project:, source: "project_delegation_pilot")
      pilot = current_rows(rows, baseline: false)
      completed = count(pilot, "issue_completed")
      started = count(pilot, "issue_started")
      decisions = event_rows(pilot, "human_decision")
      reversals = event_rows(pilot, "decision_reversed")
      metrics = {
        completed_issues: completed,
        human_decisions: decisions.size,
        decisions_per_completed_issue: rate(decisions.size, completed),
        median_decision_time_seconds: median(decisions.filter_map { |row| duration(row) }),
        completion_rate: rate(completed, started),
        reversals: reversals.size,
        material_reversals: reversals.count { |row| row.metadata["material"] == true },
        security_breaches: count(pilot, "security_breach"),
        tenant_breaches: count(pilot, "tenant_breach"),
        trust_breaches: count(pilot, "trust_breach"),
        missing_evidence: count(pilot, "evidence_missing") + pilot.count do |row|
          row.result != "evidence_missing" && row.metadata["evidence_status"] != "available"
        end
      }
      baseline = baseline_metrics(current_rows(rows, baseline: true))
      metrics[:baseline] = baseline
      Result.new(available: completed >= MIN_COMPLETED_ISSUES && observed_days(pilot) >= OBSERVATION_PERIOD / 1.day,
        reason: evidence_reason(pilot, completed), sample_count: completed,
        observed_days: observed_days(pilot), metrics: metrics)
    end

    private

    attr_reader :now, :project

    def current_rows(scope, baseline:)
      rows = scope.where("metadata ->> 'baseline' = ?", baseline.to_s).order(:occurred_at, :id).to_a
      return rows if rows.empty?

      authority = baseline ? rows.last.metadata.slice("posture_revision", "policy_signature") : current_authority
      authoritative = rows.select { |row| row.metadata.slice(*authority.keys) == authority }
      authoritative.group_by(&:subject_key).values.flat_map { |subject_rows| latest_revision_rows(subject_rows) }
    end

    def latest_revision_rows(rows)
      rows.group_by(&:result).values.map(&:last)
    end

    def current_authority
      posture = Posture.resolve_without_expansion(project)
      { "posture_revision" => posture.revision, "policy_signature" => posture.policy_signature }
    end

    def event_rows(scope, type)
      scope.select { |row| row.result == type }
    end

    def count(scope, type) = event_rows(scope, type).size

    def rate(numerator, denominator)
      return nil if denominator.zero?

      numerator.to_f / denominator
    end

    def duration(row)
      started = row.metadata["decision_started_at"]
      resolved = row.metadata["decision_resolved_at"]
      return row.metadata["duration_seconds"].to_f if row.metadata["duration_seconds"]
      return unless started && resolved

      Time.iso8601(resolved).to_f - Time.iso8601(started).to_f
    rescue ArgumentError
      nil
    end

    def median(values)
      return if values.empty?

      sorted = values.sort
      (sorted[(sorted.length - 1) / 2] + sorted[sorted.length / 2]) / 2.0
    end

    def baseline_metrics(baseline)
      completed = count(baseline, "issue_completed")
      decisions = count(baseline, "human_decision")
      {
        completed_issues: completed,
        decisions_per_completed_issue: rate(decisions, completed),
        median_decision_time_seconds: median(event_rows(baseline, "human_decision").filter_map { |row| duration(row) }),
        completion_rate: rate(completed, count(baseline, "issue_started"))
      }
    end

    def observed_days(rows)
      first = rows.map(&:occurred_at).min
      return 0 unless first

      ((now - first) / 1.day).floor
    end

    def evidence_reason(rows, completed)
      return "no_metric_evidence" if rows.empty?
      return "minimum_completed_issues_not_met" if completed < MIN_COMPLETED_ISSUES
      return "observation_period_not_met" if observed_days(rows) < OBSERVATION_PERIOD / 1.day

      nil
    end
  end
end
