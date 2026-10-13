# frozen_string_literal: true

module FeatureIntents
  # Persists and verifies the structural evidence that a planning run's issue
  # tree really exists. It deliberately does not judge whether issue prose
  # semantically covers a design; that remains an agent_harness concern.
  # @spec ISSUE-TREE-001 @spec ISSUE-TREE-002 @spec ISSUE-TREE-003
  class IssueTreeReceipt
    Result = Data.define(:complete, :state, :unresolved, :missing_native_links) do
      def complete? = complete
    end

    def self.record(...) = new(...).record
    def self.verify(...) = new(...).verify

    def initialize(feature_intent:, tasks: nil, created_issues: nil, parent_issue_number: nil, plan_revision: nil, client: nil)
      @feature_intent = feature_intent
      @tasks = Array(tasks)
      @created_issues = Array(created_issues)
      @parent_issue_number = parent_issue_number
      @plan_revision = plan_revision
      @client = client
    end

    def record
      feature_intent.update!(issue_tree_manifest: manifest, issue_tree_verification: pending_verification)
      link_local_issues
      verify
    end

    def verify
      return stale_result if stale_revision?

      unresolved = coverage_gaps + cycle_gaps + remote_gaps + linkage_gaps
      state = unresolved.empty? ? "verified" : "incomplete"
      payload = verification_payload(state:, unresolved:)
      feature_intent.update!(issue_tree_verification: payload)
      Result.new(complete: unresolved.empty?, state:, unresolved:, missing_native_links: native_link_gaps)
    end

    private

    attr_reader :feature_intent, :tasks, :created_issues, :parent_issue_number, :plan_revision, :client

    def manifest
      {
        "revision" => plan_revision,
        "parent" => qualified_reference(parent_issue_number),
        "tasks" => task_records,
        "filing_progress" => { "confirmed" => actual_by_identity.size, "expected" => tasks.size }
      }.compact
    end

    def task_records
      tasks.map.with_index do |task, index|
        identity = task_identity(task, index)
        actual = actual_by_identity[identity]
        {
          "identity" => identity,
          "title" => task[:title].to_s,
          "dependencies" => Array(task[:dependencies]).map { |dependency| task_identity_for_dependency(dependency) },
          "closeout" => task[:closeout] == true,
          "issue" => actual && qualified_reference(actual[:github_number], actual[:issue_url])
        }.compact
      end
    end

    def actual_by_identity
      @actual_by_identity ||= created_issues.to_h do |issue|
        [ task_identity(issue, issue[:index]), issue ]
      end
    end

    def task_identity(task, fallback)
      task[:identity].presence || task[:task_id].presence || "task-#{task[:index] || fallback}"
    end

    def task_identity_for_dependency(dependency)
      task = tasks.find { |candidate| candidate[:index] == dependency || task_identity(candidate, candidate[:index]) == dependency }
      task ? task_identity(task, task[:index]) : dependency.to_s
    end

    def qualified_reference(number, url = nil)
      return if number.blank?

      { "repository" => feature_intent.project.full_name, "number" => number, "url" => url }
    end

    def coverage_gaps
      task_records.filter_map { |task| "missing issue for #{task['identity']}" unless task["issue"] }
    end

    def cycle_gaps
      graph = task_records.to_h { |task| [ task["identity"], task["dependencies"] ] }
      graph.keys.filter_map { |identity| "dependency cycle at #{identity}" if cyclic?(identity, graph, []) }
    end

    def cyclic?(identity, graph, path)
      return true if path.include?(identity)
      return false unless graph.key?(identity)

      graph[identity].any? { |dependency| cyclic?(dependency, graph, path + [ identity ]) }
    end

    def remote_gaps
      return [] unless client

      task_records.filter_map do |task|
        issue = task["issue"]
        next unless issue

        begin
          remote = client.issue(issue.fetch("repository"), issue.fetch("number"))
          "remote issue missing for #{task['identity']}" unless remote
        rescue GithubClient::Error, Faraday::Error
          "remote access unknown for #{task['identity']}"
        end
      end
    end

    def linkage_gaps
      task_records.filter_map do |task|
        issue = task["issue"]
        next unless issue

        local = FeatureIntentIssue.joins(:issue).where(
          feature_intent: feature_intent,
          issues: { project_id: feature_intent.project_id, github_number: issue["number"] }
        ).exists?
        "local linkage missing for #{task['identity']}" unless local
      end
    end

    def native_link_gaps
      return [] unless parent_issue_number

      [ "native parent link unavailable; body relationship requires reconciliation" ]
    end

    def link_local_issues
      actual_by_identity.each_value do |created|
        issue = Issue.find_by(id: created[:issue_id]) || Issue.find_by(project: feature_intent.project, github_number: created[:github_number])
        AttachFromAgentRun.attach_issue(feature_intent:, issue:) if issue
      end
    end

    def stale_revision?
      recorded = feature_intent.issue_tree_manifest.to_h["revision"]
      recorded.present? && plan_revision.present? && recorded != plan_revision
    end

    def stale_result
      unresolved = [ "verification revision is stale" ]
      feature_intent.update!(issue_tree_verification: verification_payload(state: "stale", unresolved:))
      Result.new(complete: false, state: "stale", unresolved:, missing_native_links: [])
    end

    def pending_verification
      { "state" => "pending", "revision" => plan_revision, "verified_at" => nil, "unresolved" => [] }
    end

    def verification_payload(state:, unresolved:)
      {
        "state" => state,
        "revision" => plan_revision || feature_intent.issue_tree_manifest.to_h["revision"],
        "verified_at" => Time.current.iso8601,
        "unresolved" => unresolved,
        "missing_native_links" => native_link_gaps
      }
    end
  end
end
