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
      publish_operator_prerequisites!(reconcile_gaps)
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

    # Returns the human gaps so every prerequisite is visible in one Inbox
    # notification: per-gap publishes dedup onto the same row and would
    # overwrite all but the last prerequisite.
    def reconcile_gaps
      human_gaps = []
      gaps.each_with_index do |gap, index|
        if gap["kind"] == "human"
          record_gap!(index, gap, status: "awaiting_operator")
          human_gaps << gap
        else
          reconcile_agent_gap(gap, index)
        end
      end
      human_gaps
    end

    def reconcile_agent_gap(gap, index)
      owner = reusable_owner(gap) || create_owner!(gap, index)
      IssueDependency.find_or_create_by!(issue: agent_run.issue, depends_on_issue: owner)
      record_gap!(index, gap, owner_issue_id: owner.id, owner_issue_number: owner.github_number)
    end

    def reusable_owner(gap)
      number = gap["owner_issue_number"].to_i
      return if number.zero?

      owner = agent_run.project.issues.find_by(github_number: number, github_state: "open")
      # The parent cannot own its own residual gap; a self-referential edge
      # would fail IssueDependency#not_self_referential with
      # ActiveRecord::RecordInvalid, which is not a GithubClient::Error and
      # would bypass the retryable-failure path in +call+.
      owner if owner && owner.id != agent_run.issue.id
    end

    def create_owner!(gap, index)
      prior_owner(index) || begin
        title = gap["title"].to_s.strip
        raise ArgumentError, "agent gap title is required" if title.blank?

        marker = "<!-- paid:partial-closeout:#{agent_run.id}:#{index} -->"
        existing = agent_run.project.issues.where("body LIKE ?", "%#{marker}%").where(github_state: "open").first
        return existing if existing

        record_gap!(index, gap, status: "creating", marker: marker)
        created = agent_run.project.client.create_issue(
          agent_run.project.full_name,
          title: title.truncate(255), body: "#{gap["body"].to_s.strip}\n\n#{marker}", labels: owner_labels
        )
        Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: created)
      end
    end

    # Same labeling convention as the other Paid-created issue paths so the
    # owner issue routes into automation (auto-pick) and is recognizable as
    # generated; without labels it sits unpicked on labeled projects.
    def owner_labels
      labels = []
      labels << agent_run.project.automation_label_name if agent_run.project.automation_on_label_enabled?
      labels << agent_run.project.generated_label_name if agent_run.project.auto_add_labels_enabled?
      labels
    end

    def prior_owner(index)
      id = reconciliation.fetch("gaps", {}).dig(index.to_s, "owner_issue_id")
      agent_run.project.issues.find_by(id: id, github_state: "open") if id
    end

    def publish_operator_prerequisites!(human_gaps)
      return if human_gaps.empty?

      Notifications::Publish.call(
        account: agent_run.project.account, subject: agent_run.issue,
        source: "partial_closeout.prerequisite", severity: :error, blocking: true,
        title: operator_prerequisite_title(human_gaps),
        description: human_gaps.map { |gap| operator_prerequisite_step(gap) }.join("\n")
      )
    end

    def operator_prerequisite_title(human_gaps)
      criteria = human_gaps.map { |gap| gap["criterion"] }
      if criteria.one?
        "#{criteria.first} needs operator action"
      else
        "#{criteria.size} partial-closeout prerequisites need operator action"
      end
    end

    def operator_prerequisite_step(gap)
      "#{gap["criterion"]}: #{gap["next_step"].to_s.presence || "Review the recorded partial-closeout prerequisite."}"
    end

    def publish_parent_dependencies!
      numbers = agent_run.issue.issue_dependencies.includes(:depends_on_issue).filter_map { |dependency| dependency.depends_on_issue&.github_number }
      return if numbers.empty?

      lines = new_dependency_lines(numbers)
      return if lines.empty?

      updated_body = append_dependency_lines(lines)
      agent_run.project.client.update_issue(agent_run.project.full_name, agent_run.issue.github_number, body: updated_body)
      agent_run.issue.update!(body: updated_body)
    end

    def new_dependency_lines(numbers)
      body = agent_run.issue.body.to_s
      numbers.filter_map do |number|
        line = ProjectConventions::IssueDependencies.depends_on_line(project: agent_run.project, github_number: number, resolved: dependency_conventions)
        "- #{line}" unless body.match?(/\b#{Regexp.escape(line)}\b/)
      end
    end

    def append_dependency_lines(lines)
      body = agent_run.issue.body.to_s
      heading = ProjectConventions::IssueDependencies.heading(project: agent_run.project, resolved: dependency_conventions)
      return "#{body}\n#{lines.join("\n")}" if body.include?(heading)

      [ body, heading, lines.join("\n") ].reject(&:blank?).join("\n\n")
    end

    def dependency_conventions
      @dependency_conventions ||= ProjectConventions::IssueDependencies.convention_value(agent_run.project)
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
