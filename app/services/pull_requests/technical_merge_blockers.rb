# frozen_string_literal: true

module PullRequests
  # Internal merge stops are independent of human-intervention labels.
  # @spec AUTO-MERGE-012
  module TechnicalMergeBlockers
    MAX_ENTRIES = 10
    FIELDS = %w[key version head_sha reason owner_issue_id owner_issue_number release_condition recorded_by_id recorded_at].freeze
    UNAVAILABLE = { "key" => "unavailable", "reason" => "Technical blocker state is unavailable; repair its stored record.",
      "release_condition" => "Restore valid blocker state before automatic merging." }.freeze

    module_function

    def entries(issue)
      value = issue.technical_merge_blockers
      return [ UNAVAILABLE ] unless value.is_a?(Array) && value.size <= MAX_ENTRIES
      return [ UNAVAILABLE ] unless value.all? { |entry| valid_entry?(entry) }

      value.map { |entry| entry.slice(*FIELDS) }
    end

    def blocked?(issue) = entries(issue).any?

    def diagnostics(issue)
      entries(issue).map do |entry|
        { "signal" => "technical_merge_blocker", "status" => "failed", "reason_code" => "technical_merge_blocked",
          "sanitized_message" => entry.fetch("reason"), "next_action" => entry.fetch("release_condition"),
          "responsibility" => "agent", "technical_blocker" => entry }
      end
    end

    def record!(issue:, actor:, key:, head_sha:, reason:, owner_issue_id:, release_condition:)
      authorize!(issue, actor)
      validate_key!(key)
      validate_head!(head_sha)
      validate_text!(reason, "reason", 500)
      validate_text!(release_condition, "release condition", 500)
      owner = issue.project.issues.where(is_pull_request: false).find(owner_issue_id)
      entry = { "key" => key, "version" => SecureRandom.uuid, "head_sha" => head_sha,
        "reason" => reason, "owner_issue_id" => owner.id, "owner_issue_number" => owner.github_number,
        "release_condition" => release_condition,
        "recorded_by_id" => actor.id, "recorded_at" => Time.current.iso8601 }
      issue.with_lock do
        current = writable_entries!(issue).reject { |item| item.fetch("key") == key }
        raise ArgumentError, "At most #{MAX_ENTRIES} technical blockers are supported" if current.size >= MAX_ENTRIES

        issue.update!(technical_merge_blockers: current + [ entry ])
        Audit::RecordEvent.call(action: "pull_request.technical_blocker_recorded", actor:, subject: issue, metadata: entry)
      end
      entry
    end

    def resolve!(issue:, actor:, key:, version:, head_sha:, evidence:)
      authorize!(issue, actor)
      validate_key!(key)
      validate_head!(head_sha)
      validate_text!(evidence, "resolution evidence", 1000)
      inspected = writable_entries!(issue.reload).find { |item| item.fetch("key") == key }
      raise ArgumentError, "Technical blocker changed; inspect the current entry" unless inspected && inspected["version"] == version

      provider = Automation::Providers::Resolver.repository_for(issue.project)
      current_head = provider.fetch_pull_request(repo: issue.project.full_name, number: issue.github_number).head_sha
      raise ArgumentError, "PR head changed; revalidate the resolution" unless current_head == head_sha

      issue.with_lock do
        current = writable_entries!(issue)
        entry = current.find { |item| item.fetch("key") == key }
        raise ArgumentError, "Technical blocker changed; inspect the current entry" unless entry && entry["version"] == version

        issue.update!(technical_merge_blockers: current.reject { |item| item.fetch("key") == key })
        Audit::RecordEvent.call(action: "pull_request.technical_blocker_resolved", actor:, subject: issue,
          metadata: { blocker: entry, head_sha:, evidence: })
      end
      entries(issue)
    end

    def authorize!(issue, actor)
      raise Pundit::NotAuthorizedError unless actor && Pundit.policy!(actor, issue.project).manage_issues?
      raise ArgumentError, "An open pull request is required" unless issue.is_pull_request? && issue.github_state == "open"
    end

    def validate_key!(key)
      raise ArgumentError, "Invalid technical blocker key" unless key.is_a?(String) && key.match?(/\A[a-z][a-z0-9_]{0,47}\z/)
    end

    def validate_head!(head)
      raise ArgumentError, "A full observed head SHA is required" unless head.is_a?(String) && head.match?(/\A[0-9a-f]{40}\z/)
    end

    def validate_text!(value, name, limit)
      raise ArgumentError, "Invalid #{name} (1–#{limit} characters)" unless value.is_a?(String) && value.present? && value.length <= limit
    end

    def writable_entries!(issue)
      result = entries(issue)
      raise ArgumentError, "Technical blocker state is unavailable" if result.include?(UNAVAILABLE)

      result
    end

    def valid_entry?(entry)
      entry.is_a?(Hash) && (FIELDS - entry.keys).empty? &&
        entry["key"].is_a?(String) && entry["key"].match?(/\A[a-z][a-z0-9_]{0,47}\z/) &&
        entry["version"].is_a?(String) && entry["version"].length == 36 &&
        entry["head_sha"].is_a?(String) && entry["head_sha"].match?(/\A[0-9a-f]{40}\z/) &&
        %w[reason release_condition].all? { |field| entry[field].is_a?(String) && entry[field].present? && entry[field].length <= 500 } &&
        entry["owner_issue_id"].is_a?(Integer) && entry["owner_issue_number"].is_a?(Integer) && entry["recorded_by_id"].is_a?(Integer) &&
        entry["recorded_at"].is_a?(String) && entry["recorded_at"].length <= 40
    end
  end
end
