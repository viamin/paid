# frozen_string_literal: true

require "digest"

module CloseoutVerifications
  # Projects the latest terminal closeout_verification evidence per criterion
  # onto the issue's closeout audit input, mirroring
  # TechnicalPrerequisites::Evidence / TrustedMeasurements::Evidence. A record
  # whose pinned mapping, recipe, merge target, or declared environment class
  # no longer matches current state is included for provenance but flagged
  # +current: false+ with its stale reasons, so the assessment never treats
  # it as live evidence instead of silently dropping it.
  # @spec PARTIAL-CLOSEOUT-057
  class Evidence
    MAX_RECORDS = 8
    MAX_ERROR = 2_000

    Row = Data.define(:id, :issue_id, :pr_number, :base_sha, :criterion_key,
      :recipe_version, :recipe_digest, :mapping_id, :verification_result)
    PLUCK_COLUMNS = %i[id issue_id source_pull_request_number base_commit_sha closeout_criterion_key
      closeout_recipe_version closeout_recipe_digest closeout_mapping_id verification_result].freeze

    def self.records_for(issue)
      records_for_issues([ issue ]).fetch(issue.id, [])
    end

    def self.records_for_issues(issues)
      records = issues.index_by(&:id).transform_values { [] }
      return records if records.empty?

      rows = fetch_rows(records.keys)
      return records if rows.empty?

      issues_by_id = issues.index_by(&:id)
      mappings = StagedCloseoutMapping.where(id: rows.filter_map(&:mapping_id)).index_by(&:id)
      merged_shas = merged_shas_for(issues_by_id, rows)

      rows.each do |row|
        records[row.issue_id] << present(row, mapping: mappings[row.mapping_id],
          merged_sha: merged_shas[[ row.issue_id, row.pr_number ]], issue: issues_by_id.fetch(row.issue_id))
      end

      bound(latest_per_criterion(records))
    end

    def self.revision_for(issue, records: nil)
      records ||= records_for(issue)
      return if records.empty?

      semantic = records.map { |record| record.except("recorded_at") }
      Digest::SHA256.hexdigest(JSON.generate(semantic))
    end

    def self.fetch_rows(issue_ids)
      AgentRun.where(issue_id: issue_ids, goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
        status: CloseoutVerifications::Execute::TERMINAL_STATUSES).order(:id)
        .pluck(*PLUCK_COLUMNS).map { |columns| Row.new(*columns) }
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

    def self.present(row, mapping:, merged_sha:, issue:)
      evidence = row.verification_result.to_h[CloseoutVerifications::Execute::EVIDENCE_KEY].to_h
      error = evidence["error"].to_s
      reasons = stale_reasons(row, mapping:, merged_sha:, issue:)
      {
        "criterion_key" => row.criterion_key,
        "pr_number" => row.pr_number,
        "target_sha" => row.base_sha,
        "recipe_version" => row.recipe_version,
        "outcome" => evidence["outcome"],
        "recorded_at" => evidence["recorded_at"],
        "error" => error.first(MAX_ERROR),
        "error_truncated" => error.length > MAX_ERROR,
        "current" => reasons.empty?,
        "stale_reasons" => reasons
      }
    end
    private_class_method :present

    def self.stale_reasons(row, mapping:, merged_sha:, issue:)
      return [ "mapping_revoked" ] unless mapping&.current?

      reasons = []
      reasons << "recipe_changed" if mapping.target_version != row.recipe_version || mapping.target_digest != row.recipe_digest
      reasons << "target_changed" if merged_sha.present? && merged_sha != row.base_sha
      reasons << "intent_changed" if mapping.criterion_digest != StagedCloseoutMapping.digest_for(issue:, criterion_key: mapping.criterion_key)
      reasons << "environment_changed" if environment_changed?(row, mapping)
      reasons
    end
    private_class_method :stale_reasons

    def self.environment_changed?(row, mapping)
      return false if mapping.environment_class.blank?

      recorded = row.verification_result.to_h.dig(CloseoutVerifications::Execute::EVIDENCE_KEY, "environment", "mapping_environment_class")
      recorded != mapping.environment_class
    end
    private_class_method :environment_changed?

    # Rows arrive ordered oldest-to-newest, so the last entry in each
    # criterion group is the newest terminal result — the one a fresh
    # terminal outcome must supersede, whether or not it is current.
    def self.latest_per_criterion(records)
      records.transform_values do |entries|
        entries.group_by { |entry| entry["criterion_key"] }.values.map(&:last)
      end
    end
    private_class_method :latest_per_criterion

    def self.bound(records)
      records.transform_values { |entries| entries.last(MAX_RECORDS) }
    end
    private_class_method :bound
  end
end
