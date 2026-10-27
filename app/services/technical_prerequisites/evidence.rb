# frozen_string_literal: true

require "digest"

module TechnicalPrerequisites
  # Copies the latest bounded validation record to the originating run's
  # reconciliation data. The synthetic run retains the full durable record;
  # this projection is the canonical closeout-assessment input and is
  # intentionally one record per source run so retries cannot grow it without
  # bound.
  # @spec PARTIAL-CLOSEOUT-030
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
          RECONCILIATION_KEY => record.merge("validation_run_id" => agent_run.id)
        ))
      end
    end

    private

    attr_reader :agent_run, :record

    def source_run
      @source_run ||= agent_run.project.agent_runs.find_by(
        id: agent_run.external_metadata.dig(RECIPE_KEY, "source_run_id"), issue_id: agent_run.issue_id
      )
    end
  end
end
