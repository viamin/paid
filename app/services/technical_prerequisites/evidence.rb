# frozen_string_literal: true

require "digest"

module TechnicalPrerequisites
  # Copies the latest bounded validation record to the originating run's
  # reconciliation data. The synthetic run retains the full durable record;
  # performance samples are represented here only by counts and digests so the
  # canonical closeout-assessment input stays cheap to read and hash.
  # @spec PARTIAL-CLOSEOUT-032
  class Evidence
    RECONCILIATION_KEY = "technical_prerequisite_evidence"

    def self.record!(...) = new(...).record!

    def self.records_for(issue)
      records_for_issues([ issue ]).fetch(issue.id, [])
    end

    def self.records_for_issues(issues)
      records = issues.to_h { |issue| [ issue.id, [] ] }
      AgentRun.where(issue_id: records.keys).where("reconciliation ? '#{RECONCILIATION_KEY}'").order(:id)
        .pluck(:issue_id, :reconciliation).each do |issue_id, reconciliation|
          record = reconciliation.to_h[RECONCILIATION_KEY]
          records[issue_id] << record if record.is_a?(Hash)
        end
      records
    end

    def self.revision_for(issue, records: nil)
      records ||= records_for(issue)
      return if records.empty?

      Digest::SHA256.hexdigest(JSON.generate(records))
    end

    def initialize(agent_run:, record:)
      @agent_run = agent_run
      @record = record
    end

    def record!
      source_run&.with_lock do
        source_run.update!(reconciliation: source_run.reconciliation.merge(
          RECONCILIATION_KEY => reconciliation_record
        ))
      end
    end

    private

    attr_reader :agent_run, :record

    def reconciliation_record
      record.deep_dup.tap do |projection|
        summarize_samples(projection.dig("performance_measurement", "baseline"))
        summarize_samples(projection.dig("performance_measurement", "current"))
        projection["validation_run_id"] = agent_run.id
      end
    end

    def summarize_samples(measurement)
      return unless measurement.is_a?(Hash) && measurement["samples"].is_a?(Array)

      samples = measurement.delete("samples")
      measurement["sample_count"] = samples.size
      measurement["samples_digest"] = Digest::SHA256.hexdigest(JSON.generate(samples))
    end

    def source_run
      @source_run ||= agent_run.project.agent_runs.find_by(
        id: agent_run.external_metadata.dig(RECIPE_KEY, "source_run_id"), issue_id: agent_run.issue_id
      )
    end
  end
end
