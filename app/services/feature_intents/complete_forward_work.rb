# frozen_string_literal: true

module FeatureIntents
  # Routes post-admission findings without changing the scope of a running run.
  # Remote intents are persisted first; a missing read-back is always a
  # completion blocker, never an assumed success.
  # @spec CONFIDENCE-DELIVERY-008 @spec CONFIDENCE-DELIVERY-009 @spec CONFIDENCE-DELIVERY-011 @spec CONFIDENCE-DELIVERY-012
  class CompleteForwardWork
    class MissingCompletionIssueError < StandardError; end

    Result = Data.define(:completion, :item, :code) do
      def success? = code.nil?
    end

    def self.record_finding(...) = new(...).record_finding
    def self.reconcile(...) = new(...).reconcile
    def self.complete(acceptance_verified:, isolation:, release_authorized:, **attributes)
      new(**attributes).complete(acceptance_verified:, isolation:, release_authorized:)
    end

    def initialize(feature_intent:, completion_issue:, client: nil, fingerprint: nil, finding: nil, affected_issue: nil)
      @feature_intent = feature_intent
      @completion_issue = completion_issue
      @client = client || feature_intent.project.client
      @fingerprint = fingerprint
      @finding = finding.to_h.deep_stringify_keys
      @affected_issue = affected_issue
    end

    def record_finding
      item = persist_finding
      reopen_remote_completion_issue! if reopening_pending?
      route_finding!(item) unless item.reload.status == "applied"
      reconciliation = reconcile
      return Result.new(completion:, item: item.reload, code: reconciliation.code) unless reconciliation.success?

      Result.new(completion:, item: item.reload, code: nil)
    end

    def reconcile
      required_issues.each do |issue|
        return failure(:dependency_cycle) if ensure_dependency!(issue) == :cycle
      end

      Result.new(completion:, item: nil, code: nil)
    end

    def complete(acceptance_verified:, isolation:, release_authorized:)
      reconciliation = reconcile
      return reconciliation unless reconciliation.success?

      completion.with_lock do
        return failure(:pending_writes) if completion.pending_operations.present?
        return failure(:open_forward_work) if completion.forward_work_items.where(status: "pending").exists?
        return failure(:open_dependencies) if required_issues.where(github_state: "open").exists?
        return failure(:acceptance_unverified) unless acceptance_verified
        return failure(:isolation_unverified) if isolation.to_h.fetch("actual", isolation.to_h[:actual]).blank?
        return failure(:release_unauthorized) unless release_authorized

        completion.update!(
          status: "complete", completed_at: Time.current,
          release_readiness: { "acceptance_verified" => true, "isolation" => isolation, "release_authorized" => true,
                               "findings_generation" => completion.findings_generation }
        )
        Result.new(completion:, item: nil, code: nil)
      end
    end

    private

    attr_reader :affected_issue, :client, :completion_issue, :feature_intent, :finding, :fingerprint

    def completion
      @completion ||= FeatureIntentCompletion.create_or_find_by!(feature_intent:) do |record|
        record.completion_issue = completion_issue
        record.status = "pending"
      end
    end

    def persist_finding
      raise ArgumentError, "finding fingerprint is required" if fingerprint.blank?

      completion.with_lock do
        item = completion.forward_work_items.find_by(fingerprint:)
        return item if item

        item = completion.forward_work_items.create!(fingerprint:) do |item|
          item.finding = finding
          item.affected_issue = affected_issue
        end
        completion.increment!(:findings_generation)
        reserve_reopened_cycle!
        item
      end
    end

    def route_finding!(item)
      return update_unstarted_issue!(item) if suitable_unstarted_issue?(item.affected_issue)

      create_follow_up!(item)
    end

    def suitable_unstarted_issue?(issue)
      issue && issue != completion_issue && issue.github_state == "open" &&
        !issue.agent_runs.where(status: AgentRun::DEDUP_BLOCKING_STATUSES).exists?
    end

    def update_unstarted_issue!(item)
      issue = item.affected_issue
      marker = marker_for(item)
      remote_body = client.issue(feature_intent.project.full_name, issue.github_number).body.to_s
      # A prior attempt may have written remotely before the item was marked applied.
      if remote_body.include?(marker)
        issue.update!(body: remote_body)
      else
        write_issue_body!(issue, append_finding(remote_body, marker), marker:)
      end
      item.update!(status: "applied")
    end

    def create_follow_up!(item)
      issue = item.follow_up_issue || local_follow_up(item) || recovered_follow_up(item) || create_remote_follow_up!(item)
      AttachFromAgentRun.attach_issue(feature_intent:, issue: issue)
      item.update!(follow_up_issue: issue, status: "applied")
    end

    def local_follow_up(item)
      feature_intent.project.issues.where("body LIKE ?", "%#{marker_for(item)}%").first
    end

    def recovered_follow_up(item)
      return unless client.respond_to?(:search_issues)

      remote = client.search_issues("repo:#{feature_intent.project.full_name} in:body \"#{marker_for(item)}\"", per_page: 100).items
        .find { |candidate| candidate.body.to_s.include?(marker_for(item)) }
      remote && Issues::UpsertFromGithub.call(project: feature_intent.project, github_issue: remote)
    end

    def create_remote_follow_up!(item)
      mark_pending!("create:#{item.id}")
      remote = client.create_issue(
        feature_intent.project.full_name,
        title: finding.fetch("title", "Follow up: #{feature_intent.title}").truncate(255),
        body: "#{finding.fetch("body", finding.fetch("summary", "Forward work required."))}\n\n#{marker_for(item)}",
        labels: []
      )
      issue = Issues::UpsertFromGithub.call(project: feature_intent.project, github_issue: remote)
      clear_pending!("create:#{item.id}")
      issue
    end

    def reopen_remote_completion_issue!
      client.update_issue(feature_intent.project.full_name, completion_issue.github_number, state: "open")
      verified = client.issue(feature_intent.project.full_name, completion_issue.github_number)
      raise GithubClient::Error, "completion issue was not reopened" unless verified.state == "open"

      clear_pending!(reopen_key)
    end

    def ensure_dependency!(issue)
      return if issue == completion_issue
      return :cycle if Issues::DetectCycle.call(from_issue: issue, target_issue_id: completion_issue.id)

      key = "dependency:#{issue.id}"
      mark_pending!(key)
      body = client.issue(feature_intent.project.full_name, completion_issue.github_number).body.to_s
      updated_body = ProjectConventions::IssueDependencies.append_dependency_lines(
        project: feature_intent.project, github_numbers: [ issue.github_number ], body:
      )
      client.update_issue(feature_intent.project.full_name, completion_issue.github_number, body: updated_body) if updated_body != body
      verified = client.issue(feature_intent.project.full_name, completion_issue.github_number).body.to_s
      line = ProjectConventions::IssueDependencies.depends_on_line(project: feature_intent.project, github_number: issue.github_number)
      raise GithubClient::Error, "completion dependency was not read back" unless verified.include?(line)

      completion_issue.update!(body: verified)
      persist_dependency!(issue)
      clear_pending!(key)
    end

    def persist_dependency!(issue)
      IssueDependency.create_or_find_by!(issue: completion_issue, depends_on_issue: issue)
    rescue ActiveRecord::RecordInvalid => error
      raise unless duplicate_dependency?(error)

      IssueDependency.find_by!(issue: completion_issue, depends_on_issue: issue)
    end

    def duplicate_dependency?(error)
      error.record.errors.of_kind?(:depends_on_issue_id, :taken)
    end

    def required_issues
      feature_intent.issues.where.not(id: completion_issue.id)
    end

    def append_finding(body, marker)
      [ body, "## Forward work", finding.fetch("summary", "A new finding requires follow-up."), marker ].reject(&:blank?).join("\n\n")
    end

    def marker_for(item) = "<!-- paid:confidence-forward-work:#{completion.id}:#{item.fingerprint} -->"

    def mark_pending!(key)
      completion.with_lock do
        completion.update!(pending_operations: completion.pending_operations.merge(key => Time.current.iso8601))
      end
    end

    def clear_pending!(key)
      completion.with_lock do
        completion.update!(pending_operations: completion.pending_operations.except(key))
      end
    end

    def reserve_reopened_cycle!
      return unless completion.status == "complete"

      completion.update!(
        status: "pending", completed_at: nil, cycle: completion.cycle + 1,
        pending_operations: completion.pending_operations.merge(reopen_key => Time.current.iso8601)
      )
    end

    def reopening_pending? = completion.pending_operations.key?(reopen_key)

    def reopen_key = "reopen:#{completion.id}"

    def write_issue_body!(issue, body, marker:)
      client.update_issue(feature_intent.project.full_name, issue.github_number, body: body)
      verified = client.issue(feature_intent.project.full_name, issue.github_number).body.to_s
      raise GithubClient::Error, "unstarted issue update was not read back" unless verified.include?(marker)

      issue.update!(body: verified)
    end

    def failure(code) = Result.new(completion:, item: nil, code:)
  end
end
