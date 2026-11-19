# frozen_string_literal: true

require "digest"

module CloseoutVerifications
  # Bounded primary evidence for semantic acceptance. Freshness is structural:
  # a passing command never mechanically satisfies an issue criterion.
  # @spec PARTIAL-CLOSEOUT-057
  class Evidence
    MAX_RECORDS = 8
    MAX_ERROR = 2_000
    MAX_OUTPUT_BYTES = 2_000
    MAX_COMMAND_BYTES = 1_000

    Row = Data.define(:id, :issue_id, :pr_number, :base_sha, :criterion_key,
      :recipe_version, :recipe_digest, :mapping_id, :verification_result)
    PLUCK_COLUMNS = %i[id issue_id source_pull_request_number base_commit_sha closeout_criterion_key
      closeout_recipe_version closeout_recipe_digest closeout_mapping_id verification_result].freeze

    def self.records_for(issue)
      records_for_issues([ issue ]).fetch(issue.id, [])
    end

    def self.records_for_issues(issues)
      bound(project_records(issues))
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
      latest_ids = rows.to_h { |row| [ [ row.issue_id, row.criterion_key ], row.id ] }
      rows.each do |row|
        records[row.issue_id] << present(row, mapping: mappings[row.mapping_id],
          merged_sha: merged_shas[[ row.issue_id, row.pr_number ]], issue: issues_by_id.fetch(row.issue_id),
          superseded: latest_ids[[ row.issue_id, row.criterion_key ]] != row.id)
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

    def self.present(row, mapping:, merged_sha:, issue:, superseded:)
      evidence = row.verification_result.to_h[CloseoutVerifications::Execute::EVIDENCE_KEY].to_h
      technical = evidence["technical_evidence"].to_h
      native = technical["native"].to_h
      reasons = stale_reasons(row, mapping:, merged_sha:, issue:, evidence:)
      reasons << "superseded_result" if superseded
      strings = { "error" => [ evidence["error"].to_s, MAX_ERROR ],
        "command" => [ evidence["command"].to_s, MAX_COMMAND_BYTES ],
        "stdout" => [ native["stdout"].to_s, MAX_OUTPUT_BYTES ],
        "stderr" => [ native["stderr"].to_s, MAX_OUTPUT_BYTES ] }
      {
        "verification_run_id" => row.id, "source_issue_id" => issue.id, "project_id" => issue.project_id,
        "criterion_key" => row.criterion_key, "pr_number" => row.pr_number, "target_sha" => row.base_sha,
        "recipe_version" => row.recipe_version, "recipe_digest" => row.recipe_digest,
        "outcome" => evidence["outcome"], "recorded_at" => evidence["recorded_at"],
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
    end
    private_class_method :present

    def self.bounded(value, limit)
      value.byteslice(0, limit).to_s.scrub("")
    end
    private_class_method :bounded

    def self.stale_reasons(row, mapping:, merged_sha:, issue:, evidence:)
      return [ "mapping_revoked" ] unless mapping&.current?
      return [ "mapping_scope_mismatch" ] unless mapping.issue_id == issue.id &&
        mapping.project_id == issue.project_id && mapping.account_id == mapping.project.account_id && mapping.criterion_key == row.criterion_key

      reasons = []
      reasons << "recipe_changed" if mapping.target_version != row.recipe_version || mapping.target_digest != row.recipe_digest ||
        !StagedCloseoutAdoption::Mappings.target_current?(mapping:, project: mapping.project)
      reasons << "target_changed" if merged_sha.blank? || merged_sha != row.base_sha
      reasons << "intent_changed" if mapping.criterion_digest != StagedCloseoutMapping.digest_for(issue:, criterion_key: mapping.criterion_key)
      reasons << "environment_changed" if environment_changed?(evidence, mapping)
      expected = { "source_issue_id" => issue.id, "criterion" => row.criterion_key, "source_pr_number" => row.pr_number,
        "merged_commit_sha" => row.base_sha, "recipe_version" => row.recipe_version,
        "recipe_digest" => row.recipe_digest, "mapping_id" => row.mapping_id }
      reasons << "verification_identity_mismatch" unless expected.all? { |key, value| evidence[key].to_s == value.to_s }
      reasons
    end
    private_class_method :stale_reasons

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
