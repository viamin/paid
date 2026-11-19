# frozen_string_literal: true

require "digest"

module CloseoutVerifications
  # Bounded primary evidence for semantic acceptance. Currentness requires
  # reviewed bindings and lifetime; a passing command never satisfies a criterion.
  # @spec PARTIAL-CLOSEOUT-057
  class Evidence
    MAX_RECORDS = 8
    MAX_ERROR = 2_000
    MAX_OUTPUT_BYTES = 2_000
    MAX_COMMAND_BYTES = 1_000

    Row = Data.define(:id, :issue_id, :pr_number, :base_sha, :criterion_key,
      :recipe_version, :recipe_digest, :mapping_id, :completed_at, :verification_result,
      :target_revision, :environment_class, :measurement_attempt_id, :generation)
    PLUCK_COLUMNS = %i[id issue_id source_pull_request_number base_commit_sha closeout_criterion_key
      closeout_recipe_version closeout_recipe_digest closeout_mapping_id completed_at verification_result
      closeout_target_revision closeout_environment closeout_measurement_attempt_id closeout_verification_generation].freeze

    def self.records_for(issue)
      records_for_issues([ issue ]).fetch(issue.id, [])
    end

    def self.records_for_issues(issues)
      bound(project_records(issues))
    end

    # Complete current terminal observations may authorize a report-only audit,
    # never ordinary implementation or a semantic acceptance verdict.
    # @spec STAGED-CLOSEOUT-ADOPTION-015
    def self.audit_ready?(issue) = audit_ready_records?(records_for(issue))

    def self.audit_ready_records?(records)
      complete = records.none? { |record| record["evidence_truncated"] || record["omitted_record_count"].to_i.positive? }
      outcomes = %w[passed observed failed unavailable timeout setup_failed cleanup_failed]
      complete && records.any? { |record| record["current"] && record["outcome"].in?(outcomes) }
    end

    def self.current_for_run?(agent_run)
      return false unless agent_run.issue

      project_records([ agent_run.issue ]).fetch(agent_run.issue_id, []).any? do |record|
        record["verification_run_id"] == agent_run.id && record["current"]
      end
    end

    def self.project_records(issues)
      records = issues.index_by(&:id).transform_values { [] }
      return records if records.empty?

      rows = fetch_rows(issues)
      return records if rows.empty?

      issues_by_id = issues.index_by(&:id)
      mappings = StagedCloseoutMapping.where(id: rows.filter_map(&:mapping_id)).includes(:project).index_by(&:id)
      merged_shas = merged_shas_for(issues_by_id, rows)
      measurements = TrustedMeasurementAttempt.where(id: rows.filter_map(&:measurement_attempt_id),
        issue_id: records.keys, project_id: issues.map(&:project_id)).index_by(&:id)
      live_revision = TrustedMeasurements::DeploymentSignal.current if rows.any? { |row| row.target_revision.present? }
      observed_at = Time.current
      latest_ids = rows.to_h { |row| [ [ row.issue_id, row.criterion_key ], row.id ] }
      rows.each do |row|
        records[row.issue_id] << present(row, mapping: mappings[row.mapping_id],
          merged_sha: merged_shas[[ row.issue_id, row.pr_number ]], issue: issues_by_id.fetch(row.issue_id),
          superseded: latest_ids[[ row.issue_id, row.criterion_key ]] != row.id, observed_at:,
          measurement: measurements[row.measurement_attempt_id], live_revision:)
      end
      records
    end
    private_class_method :project_records

    def self.revision_for(issue, records: nil)
      records ||= records_for(issue)
      return if records.empty?

      Digest::SHA256.hexdigest(JSON.generate(records.map { |record| record.except("recorded_at") }))
    end

    def self.fetch_rows(issues)
      scopes = issues.group_by(&:project_id).map do |project_id, group|
        AgentRun.where(project_id:, issue_id: group.map(&:id))
      end
      scope = scopes.reduce { |combined, candidate| combined.or(candidate) }
        .where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL, synthetic: true,
          status: CloseoutVerifications::Execute::TERMINAL_STATUSES)
      scope.order(:id).pluck(*PLUCK_COLUMNS).map { |columns| Row.new(*columns) }
    end
    private_class_method :fetch_rows

    def self.merged_shas_for(issues_by_id, rows)
      numbers_by_project = rows.group_by { |row| issues_by_id.fetch(row.issue_id).project_id }
        .transform_values { |group| group.map(&:pr_number).uniq }
      sha_by_project_and_number = numbers_by_project.flat_map do |project_id, numbers|
        Issue.where(project_id:, is_pull_request: true, pr_review_phase: "merged", github_number: numbers)
          .pluck(:github_number, :merged_commit_sha).map { |number, sha| [ [ project_id, number ], sha ] }
      end.to_h
      rows.to_h do |row|
        key = [ issues_by_id.fetch(row.issue_id).project_id, row.pr_number ]
        [ [ row.issue_id, row.pr_number ], sha_by_project_and_number[key] ]
      end
    end
    private_class_method :merged_shas_for

    def self.present(row, mapping:, merged_sha:, issue:, superseded:, observed_at:, measurement:, live_revision:)
      evidence = row.verification_result.to_h[CloseoutVerifications::Execute::EVIDENCE_KEY].to_h
      technical = evidence["technical_evidence"].to_h
      native = technical["native"].to_h
      reasons = stale_reasons(row, mapping:, merged_sha:, issue:, evidence:, measurement:, live_revision:)
      reasons << "superseded_result" if superseded
      expires_at = row.completed_at + mapping.freshness_seconds if row.completed_at && mapping
      if reasons.empty?
        if row.completed_at.nil?
          reasons << "verification_time_unavailable"
        elsif row.completed_at > observed_at
          reasons << "verification_time_in_future"
        elsif expires_at && expires_at <= observed_at
          reasons << "verification_expired"
        end
      end
      strings = { "error" => [ evidence["error"].to_s, MAX_ERROR ],
        "command" => [ evidence["command"].to_s, MAX_COMMAND_BYTES ],
        "stdout" => [ native["stdout"].to_s, MAX_OUTPUT_BYTES ],
        "stderr" => [ native["stderr"].to_s, MAX_OUTPUT_BYTES ] }
      record = {
        "verification_run_id" => row.id, "mapping_id" => row.mapping_id, "generation" => row.generation,
        "source_issue_id" => issue.id, "project_id" => issue.project_id,
        "criterion_key" => row.criterion_key, "pr_number" => row.pr_number, "target_sha" => row.target_revision.presence || row.base_sha,
        "recipe_version" => row.recipe_version, "recipe_digest" => row.recipe_digest,
        "outcome" => evidence["outcome"], "recorded_at" => evidence["recorded_at"],
        "completed_at" => row.completed_at&.utc&.iso8601(6), "expires_at" => expires_at&.utc&.iso8601(6),
        "freshness_seconds" => mapping&.freshness_seconds,
        "error" => bounded(*strings.fetch("error")), "error_truncated" => strings.fetch("error").first.bytesize > MAX_ERROR,
        "command" => bounded(*strings.fetch("command")),
        "native" => { "exit_code" => native["exit_code"], "stdout" => bounded(*strings.fetch("stdout")),
          "stderr" => bounded(*strings.fetch("stderr")) },
        "environment" => evidence["environment"].to_h.slice("container_id", "container_host", "mapping_environment_class")
          .transform_values { |value| value.nil? ? nil : bounded(value.to_s, 250) },
        "cleanup_completed" => technical.dig("cleanup", "completed"),
        "evidence_truncated" => strings.values.any? { |value, limit| value.bytesize > limit },
        "receipt_digest" => Digest::SHA256.hexdigest(JSON.generate(evidence.except("recorded_at"))),
        "current" => reasons.empty?,
        "stale_reasons" => reasons
      }
      record.merge!(measurement_fields(row, evidence, record)) if live_target?(row, mapping)
      record
    end
    private_class_method :present

    def self.bounded(value, limit)
      value.byteslice(0, limit).to_s.scrub("")
    end
    private_class_method :bounded

    def self.stale_reasons(row, mapping:, merged_sha:, issue:, evidence:, measurement:, live_revision:)
      return [ "mapping_revoked" ] unless mapping&.current?
      return [ "mapping_scope_mismatch" ] unless mapping.issue_id == issue.id &&
        mapping.project_id == issue.project_id && mapping.account_id == mapping.project.account_id && mapping.criterion_key == row.criterion_key

      reasons = []
      reasons << "recipe_changed" if mapping.target_version != row.recipe_version || mapping.target_digest != row.recipe_digest ||
        !StagedCloseoutAdoption::Mappings.target_current?(mapping:, project: mapping.project)
      if live_target?(row, mapping)
        reasons.concat(live_stale_reasons(row, mapping:, issue:, evidence:, measurement:, live_revision:))
      else
        reasons << "target_changed" if merged_sha.blank? || merged_sha != row.base_sha
      end
      reasons << "intent_changed" if mapping.criterion_digest != StagedCloseoutMapping.digest_for(issue:, criterion_key: mapping.criterion_key)
      reasons << "environment_changed" if environment_changed?(evidence, mapping)
      expected = { "source_issue_id" => issue.id, "criterion" => row.criterion_key, "source_pr_number" => row.pr_number,
        "merged_commit_sha" => row.base_sha, "recipe_version" => row.recipe_version,
        "recipe_digest" => row.recipe_digest, "mapping_id" => row.mapping_id }
      expected["generation"] = row.generation unless row.generation.zero? && !evidence.key?("generation")
      reasons << "verification_identity_mismatch" unless expected.all? { |key, value| evidence[key].to_s == value.to_s }
      reasons
    end
    private_class_method :stale_reasons

    def self.live_target?(row, mapping)
      row.target_revision.present? || mapping&.stage == "live_environment"
    end
    private_class_method :live_target?

    def self.live_stale_reasons(row, mapping:, issue:, evidence:, measurement:, live_revision:)
      reasons = []
      reasons << "target_changed" if live_revision.blank? || row.target_revision != live_revision
      reasons << "environment_changed" unless row.environment_class == mapping.environment_class && row.environment_class == Rails.env.to_s
      reasons << "verification_identity_mismatch" unless evidence["target_revision"] == row.target_revision &&
        evidence["measurement_attempt_id"] == row.measurement_attempt_id
      unless measurement && measurement.account_id == mapping.account_id && measurement.project_id == issue.project_id &&
          measurement.issue_id == issue.id && measurement.external_issue_number == issue.github_number &&
          measurement.criterion_key == row.criterion_key && measurement.check_key == mapping.target_key &&
          measurement.check_version.to_s == row.recipe_version && measurement.deployed_revision == row.target_revision
        return reasons + [ "measurement_unavailable_or_mismatched" ]
      end

      unless measurement.status == evidence["measurement_status"] && measurement.result == evidence["measurement_result"] &&
          measurement.failure_reason.to_s == evidence["measurement_failure_reason"].to_s &&
          measurement.executed_at&.utc&.iso8601(6) == evidence["measurement_executed_at"]
        reasons << "measurement_changed"
      end
      reasons
    end
    private_class_method :live_stale_reasons

    def self.measurement_fields(row, evidence, record)
      raw_result = evidence["measurement_result"]
      result = raw_result.is_a?(Hash) ? raw_result : {}
      encoded = JSON.generate(result)
      truncated = encoded.bytesize > MAX_OUTPUT_BYTES || row.target_revision.to_s.bytesize > 250 ||
        evidence["measurement_failure_reason"].to_s.bytesize > MAX_ERROR
      {
        "stage" => "live_environment", "target_revision" => bounded(row.target_revision.to_s, 250),
        "measurement_attempt_id" => row.measurement_attempt_id,
        "measurement_status" => bounded(evidence["measurement_status"].to_s, 50),
        "measurement_executed_at" => bounded(evidence["measurement_executed_at"].to_s, 50),
        "measurement_failure_reason" => bounded(evidence["measurement_failure_reason"].to_s, MAX_ERROR),
        "measurement_result" => truncated ? bounded(encoded, MAX_OUTPUT_BYTES) : result,
        "evidence_truncated" => record["evidence_truncated"] || truncated
      }
    end
    private_class_method :measurement_fields

    def self.environment_changed?(evidence, mapping)
      mapping.environment_class.present? && evidence.dig("environment", "mapping_environment_class") != mapping.environment_class
    end
    private_class_method :environment_changed?

    def self.bound(records)
      records.transform_values do |entries|
        omitted = entries.first([ entries.size - MAX_RECORDS, 0 ].max)
        selected = entries.last(MAX_RECORDS)
        if omitted.any?
          selected[0] = selected.first.merge("omitted_record_count" => omitted.size,
            "omitted_revision" => Digest::SHA256.hexdigest(JSON.generate(omitted.map { |record| record.except("recorded_at") })))
        end
        selected
      end
    end
    private_class_method :bound
  end
end
