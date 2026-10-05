# frozen_string_literal: true

module PartialCloseouts
  # Turns a validated semantic assessment into durable, replay-safe work owners.
  class Reconcile
    MAX_GAPS = 10

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, assessment:)
      @agent_run = agent_run
      @assessment = assessment.to_h.deep_stringify_keys
    end

    def call # @spec NO-OUTPUT-ISSUE-007
      validate!
      gaps.each_with_index { |gap, index| reconcile_gap(gap, index) }
      publish_parent_dependencies!
      finalize!
    rescue GithubClient::Error => e
      record_failure!(e)
      raise
    end

    private

    attr_reader :agent_run, :assessment

    def gaps = assessment.fetch("gaps")

    def validate!
      raise ArgumentError, "partial closeout requires an issue" unless agent_run.issue
      raise ArgumentError, "gaps must be an array of at most #{MAX_GAPS}" unless gaps.is_a?(Array) && gaps.size <= MAX_GAPS

      gaps.each { |gap| raise ArgumentError, "gap criterion is required" if gap["criterion"].blank? }
    end

    def reconcile_gap(gap, index)
      return record_operator_prerequisite!(gap, index) if gap["kind"] == "human"

      owner = reusable_owner(gap) || create_owner!(gap, index)
      IssueDependency.find_or_create_by!(issue: agent_run.issue, depends_on_issue: owner)
      record_gap!(index, gap, owner_issue_id: owner.id, owner_issue_number: owner.github_number)
    end

    def reusable_owner(gap)
      number = gap["owner_issue_number"].to_i
      return if number.zero?

      agent_run.project.issues.find_by(github_number: number, github_state: "open")
    end

    def create_owner!(gap, index)
      prior_owner(index) || begin
        title = gap.fetch("title").to_s.strip
        raise ArgumentError, "agent gap title is required" if title.blank?

        marker = "<!-- paid:partial-closeout:#{agent_run.id}:#{index} -->"
        existing = agent_run.project.issues.where("body LIKE ?", "%#{marker}%").where(github_state: "open").first
        return existing if existing

        record_gap!(index, gap, status: "creating", marker: marker)
        created = agent_run.project.client.create_issue(
          agent_run.project.full_name,
          title: title.truncate(255), body: "#{gap["body"].to_s.strip}\n\n#{marker}"
        )
        Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: created)
      end
    end

    def prior_owner(index)
      id = reconciliation.fetch("gaps", {}).dig(index.to_s, "owner_issue_id")
      agent_run.project.issues.find_by(id: id, github_state: "open") if id
    end

    def record_operator_prerequisite!(gap, index)
      record_gap!(index, gap, status: "awaiting_operator")
      Notifications::Publish.call(
        account: agent_run.project.account, subject: agent_run.issue,
        source: "partial_closeout.prerequisite", severity: :error, blocking: true,
        title: "#{gap["criterion"]} needs operator action",
        description: gap.fetch("next_step").to_s.presence || "Review the recorded partial-closeout prerequisite."
      )
    end

    def publish_parent_dependencies!
      numbers = agent_run.issue.issue_dependencies.includes(:depends_on_issue).filter_map { |dependency| dependency.depends_on_issue&.github_number }
      return if numbers.empty?

      body = agent_run.issue.body.to_s
      lines = numbers.reject { |number| body.include?("Depends on ##{number}") }.map { |number| "- Depends on ##{number}" }
      return if lines.empty?

      updated_body = [ body, "## Dependencies", *lines ].reject(&:blank?).join("\n\n")
      agent_run.project.client.update_issue(agent_run.project.full_name, agent_run.issue.github_number, body: updated_body)
      agent_run.issue.update!(body: updated_body)
    end

    def finalize!
      status = reconciliation.fetch("gaps", {}).values.any? { |gap| gap["status"] == "awaiting_operator" } ? "awaiting_operator" : "reconciled"
      agent_run.update!(reconciliation: reconciliation.merge("status" => status, "reconciled_at" => Time.current.iso8601))
    end

    def record_failure!(error)
      agent_run.update!(reconciliation: reconciliation.merge("status" => "retryable_failure", "error" => error.message, "failed_at" => Time.current.iso8601))
    end

    def record_gap!(index, gap, attributes = {})
      state = reconciliation.fetch("gaps", {}).merge(index.to_s => gap.merge(attributes.stringify_keys))
      agent_run.update!(reconciliation: reconciliation.merge("gaps" => state, "status" => "reconciling"))
    end

    def reconciliation = agent_run.reconciliation.to_h.deep_stringify_keys
  end
end
