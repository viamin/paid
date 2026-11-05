# frozen_string_literal: true

module ProjectDelegation
  # @spec PROJECT-DELEGATION-007
  class PilotMetrics
    MIN_COMPLETED_ISSUES = 30
    MIN_PILOT_DAYS = 14
    CohortMetrics = Data.define(
      :completed_issues, :inbox_decisions, :decision_rate, :median_decision_time,
      :p95_decision_time, :completion_rate, :reversal_count, :reversal_rate
    )

    Snapshot = Data.define(
      :completed_issues, :inbox_decisions, :decision_rate, :median_decision_time,
      :p95_decision_time, :completion_rate, :reversal_count, :reversal_rate,
      :pause_reasons, :evidence_complete?, :window_days, :baseline
    ) do
      def threshold_met?
        completed_issues >= PilotMetrics::MIN_COMPLETED_ISSUES &&
          window_days >= PilotMetrics::MIN_PILOT_DAYS && baseline &&
          decision_rate <= baseline.decision_rate * 0.75 &&
          median_decision_time <= baseline.median_decision_time &&
          completion_rate >= baseline.completion_rate - 0.05 &&
          reversal_count.zero? && pause_reasons.empty? && evidence_complete?
      end
    end

    def self.call(project:) = new(project:).call

    def initialize(project:)
      @project = project
    end

    def call
      pilot = cohort_metrics("pilot")
      baseline = cohort_metrics("baseline")
      Snapshot.new(
        **pilot,
        pause_reasons: pause_reasons,
        evidence_complete?: evidence_complete?,
        window_days: window_days,
        baseline: baseline
      )
    end

    private

    attr_reader :project

    def events
      @events ||= project.project_delegation_metrics.order(:occurred_at).to_a
    end

    def cohort_metrics(cohort)
      cohort_events = events.select { |event| event.cohort == cohort }
      completions = cohort_events.select { |event| event.event_type == "issue_completed" }
      decisions = cohort_events.select { |event| event.event_type == "inbox_decision" }
        .select { |event| revision_match?(event, completions) }
      started = cohort_events.count { |event| event.event_type == "issue_started" }
      started = completions.size if started.zero?
      durations = decisions.filter_map { |decision| decision_duration(decision, completions) }

      CohortMetrics.new(
        completed_issues: completions.size,
        inbox_decisions: decisions.size,
        decision_rate: ratio(decisions.size, completions.size),
        median_decision_time: median(durations),
        p95_decision_time: percentile(durations, 0.95),
        completion_rate: ratio(completions.size, started),
        reversal_count: cohort_events.count { |event| event.event_type == "material_reversal" },
        reversal_rate: ratio(cohort_events.count { |event| event.event_type == "material_reversal" }, completions.size)
      )
    end

    def revision_match?(decision, completions)
      completions.any? { |completion| completion.issue_key == decision.issue_key && same_revisions?(completion, decision) }
    end

    def decision_duration(decision, completions)
      completion = completions.find do |candidate|
        candidate.issue_key == decision.issue_key && same_revisions?(candidate, decision)
      end
      completion && (completion.occurred_at - decision.occurred_at).to_f
    end

    def same_revisions?(left, right)
      left.intent_revision == right.intent_revision &&
        left.acceptance_revision == right.acceptance_revision &&
        left.evidence_revision == right.evidence_revision
    end

    def pause_reasons
      events.filter_map do |event|
        case event.event_type
        when "material_reversal" then "material_reversal"
        when "security_breach" then "security_breach"
        when "tenant_breach" then "tenant_breach"
        when "trust_breach" then "trust_breach"
        when "evidence_missing" then "missing_evidence"
        end
      end.uniq
    end

    def evidence_complete?
      events.none? { |event| event.event_type == "evidence_missing" }
    end

    def window_days
      first = events.select { |event| event.cohort == "pilot" }.min_by(&:occurred_at)&.occurred_at
      return 0.0 unless first

      ((Time.current - first) / 1.day).round(2)
    end

    def ratio(numerator, denominator)
      return 0.0 if denominator.to_i.zero?

      (numerator.to_f / denominator).round(4)
    end

    def median(values)
      percentile(values, 0.5)
    end

    def percentile(values, percentile)
      return 0.0 if values.empty?

      sorted = values.sort
      sorted[((sorted.length - 1) * percentile).ceil]
    end
  end
end
