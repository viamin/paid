# frozen_string_literal: true

module CloseoutVerifications
  # Structural prerequisite for closure, independent of the semantic verdict.
  # A reviewed stage cannot be bypassed by a newer optimistic acceptance audit.
  # @spec STAGED-CLOSEOUT-ADOPTION-013
  class ClosureReadiness
    Blocker = Data.define(:criterion_key, :code, :next_action)
    Result = Data.define(:blockers) do
      def ready? = blockers.empty?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, criteria: nil)
      @issue = issue
      @criteria = criteria
    end

    def call
      Result.new(requirements.filter_map { |mapping| blocker_for(mapping) })
    end

    def requirements
      @requirements ||= issue.project.staged_closeout_mappings.where(issue:)
        .order(:criterion_key, revision: :desc).to_a.uniq(&:criterion_key)
        .select do |mapping|
          mapping.stage.in?(%w[merged_revision live_environment]) &&
            (criteria.include?(mapping.criterion_key) ||
              mapping.criterion_digest == StagedCloseoutMapping.digest_for(issue:, criterion_key: mapping.criterion_key))
        end
    end

    private

    attr_reader :issue

    def criteria = @criteria ||= PartialCloseouts::Assessment.call(issue).criteria.pluck("criterion")

    def records = @records ||= Evidence.records_for(issue)

    def blocker_for(mapping)
      unless criteria.include?(mapping.criterion_key)
        return blocker(mapping, :criterion_not_assessed, "Request an acceptance audit that covers the reviewed required criterion.")
      end
      unless mapping.current?
        return blocker(mapping, :mapping_revoked, "Review and approve the required verification mapping.")
      end
      if records.any? { |record| record["evidence_truncated"] || record["omitted_record_count"].to_i.positive? }
        return blocker(mapping, :evidence_incomplete, "Review incomplete verification evidence before requesting a new acceptance audit.")
      end

      record = records.reverse.find { |entry| entry["mapping_id"] == mapping.id }
      return blocker(mapping, :verification_missing, "Wait for the required verification to run for the confirmed target.") unless record
      unless record["current"]
        return blocker(mapping, :verification_stale, "Collect current verification evidence for the reviewed target, then request an acceptance audit.")
      end
      return if successful?(mapping, record)

      blocker(mapping, :verification_failed, "Inspect the failed check before collecting current evidence and requesting a new acceptance audit.")
    end

    def successful?(mapping, record)
      if mapping.stage == "live_environment"
        record["outcome"] == "observed" && record["measurement_status"] == "succeeded"
      else
        record["outcome"] == "passed" && record.dig("native", "exit_code") == 0 && record["cleanup_completed"] == true
      end
    end

    def blocker(mapping, code, next_action)
      Blocker.new(mapping.criterion_key, code, next_action)
    end
  end
end
