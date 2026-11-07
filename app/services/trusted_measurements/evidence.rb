# frozen_string_literal: true

require "digest"

module TrustedMeasurements
  # Projects the latest trusted-measurement attempt per (check, criterion)
  # onto an issue for the closeout assessment prompt, mirroring
  # TechnicalPrerequisites::Evidence. A stale attempt (collected against a
  # revision that is no longer the deployed one) is included for provenance
  # but flagged +current: false+ so the assessment never treats it as live
  # evidence — the prompt is told explicitly, rather than silently
  # dropping the row and leaving the gap unexplained.
  # @spec TRUSTED-MEASUREMENTS-005
  class Evidence
    def self.records_for(issue)
      records_for_issues([ issue ]).fetch(issue.id, [])
    end

    def self.records_for_issues(issues)
      records = issues.index_by(&:id).transform_values { [] }
      return records if records.empty?

      TrustedMeasurementAttempt.where(issue_id: records.keys).order(:id).each do |attempt|
        records[attempt.issue_id] << present(attempt)
      end
      latest_per_check(records)
    end

    def self.revision_for(issue, records: nil)
      records ||= records_for(issue)
      return if records.empty?

      semantic_records = records.map { |record| record.except("executed_at") }
      Digest::SHA256.hexdigest(JSON.generate(semantic_records))
    end

    def self.present(attempt)
      {
        "check_key" => attempt.check_key,
        "check_version" => attempt.check_version,
        "criterion_key" => attempt.criterion_key,
        "status" => attempt.status,
        "result" => attempt.result,
        "account_id" => attempt.account_id,
        "project_id" => attempt.project_id,
        "deployed_revision" => attempt.deployed_revision,
        "executed_at" => attempt.executed_at&.iso8601,
        "current" => attempt.succeeded? && attempt.current_for_revision?(DeploymentSignal.current)
      }
    end
    private_class_method :present

    def self.latest_per_check(records)
      records.transform_values do |attempts|
        attempts.group_by { |record| [ record["check_key"], record["criterion_key"] ] }
          .values.map { |group| group.find { |record| record["current"] } || group.last }
      end
    end
    private_class_method :latest_per_check
  end
end
