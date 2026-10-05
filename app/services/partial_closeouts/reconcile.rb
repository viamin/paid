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

      gaps.each do |gap|
        raise ArgumentError, "gap criterion is required" if gap["criterion"].blank?
        # Mirrors Llm::AnalyzePartialCloseout#owner_resolvable? so the exact
        # operator next step reaches the Inbox notification; a generic
        # fallback would leave the prerequisite unactionable (#4119).
        raise ArgumentError, "human gap next_step is required" if human_gap?(gap) && gap["next_step"].to_s.strip.blank?
      end
    end

    def human_gap?(gap)
      gap["kind"] == "human"
    end

    # Returns the human gaps so every prerequisite is visible in one Inbox
    # notification: per-gap publishes dedup onto the same row and would
    # overwrite all but the last prerequisite.
    def reconcile_gaps
      human_gaps = []
      gaps.each_with_index do |gap, index|
        if human_gap?(gap)
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

        marker = owner_marker(index)
        existing = local_owner_with_marker(marker)
        return existing if existing
        recovered = recovered_remote_owner(marker) if creation_was_recorded?(index, marker)
        return recovered if recovered

        record_gap!(index, gap, status: "creating", marker: marker)
        created = agent_run.project.client.create_issue(
          agent_run.project.full_name,
          title: title.truncate(255), body: "#{gap["body"].to_s.strip}\n\n#{marker}", labels: owner_labels
        )
        # Persist the created number BEFORE the local upsert so a crash
        # between the GitHub call and the upsert is still recoverable on
        # retry via prior_owner's number lookup.
        record_gap!(index, gap, status: "creating", marker: marker, owner_issue_number: created.number)
        Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: created)
      end
    end

    def owner_marker(index)
      "<!-- paid:partial-closeout:#{agent_run.id}:#{index} -->"
    end

    def local_owner_with_marker(marker)
      owner = agent_run.project.issues.where("body LIKE ?", "%#{marker}%").where(github_state: "open").first
      owner if owner && owner.id != agent_run.issue.id
    end

    # A worker can terminate after GitHub accepts create_issue but before the
    # response number is persisted. The durable pre-request marker distinguishes
    # that replay from a first attempt; recover the remote issue before sending
    # another create request.
    def creation_was_recorded?(index, marker)
      state = reconciliation.fetch("gaps", {}).fetch(index.to_s, {})
      state["status"] == "creating" && state["marker"] == marker
    end

    def recovered_remote_owner(marker)
      remote_owner = agent_run.project.client.search_issues(remote_owner_query(marker), per_page: 100).items
        .find { |issue| issue.body.to_s.include?(marker) }
      return unless remote_owner

      owner = Issues::UpsertFromGithub.call(project: agent_run.project, github_issue: remote_owner)
      owner if owner.id != agent_run.issue.id && owner.github_state == "open"
    end

    def remote_owner_query(marker)
      %(repo:#{agent_run.project.full_name} is:issue state:open in:body "#{marker}")
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
      state = reconciliation.fetch("gaps", {}).fetch(index.to_s, {})
      owner_from_id(state) || owner_from_number(state)
    end

    def owner_from_id(state)
      return unless state["owner_issue_id"]

      agent_run.project.issues.find_by(id: state["owner_issue_id"], github_state: "open")
    end

    # Recovers a gap whose GitHub issue was created but whose local owner row
    # was never linked back (crash between create_issue and the upsert): the
    # replay state carries the created number, and a later sync may have
    # landed the row. Same parent exclusion as reusable_owner so a recorded
    # number pointing at the parent cannot create a self-referential edge.
    def owner_from_number(state)
      number = state["owner_issue_number"].to_i
      return if number.zero?

      owner = agent_run.project.issues.find_by(github_number: number, github_state: "open")
      owner if owner && owner.id != agent_run.issue.id
    end

    def publish_operator_prerequisites!(human_gaps)
      return if human_gaps.empty?

      Notifications::Publish.call(
        account: agent_run.project.account, subject: agent_run.issue,
        source: PREREQUISITE_NOTIFICATION_SOURCE, severity: :error, blocking: true,
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

    # validate! guarantees a nonblank exact step for every human gap, so the
    # Inbox item always tells the operator what to do — never a generic
    # "review the prerequisite" placeholder (#4119).
    def operator_prerequisite_step(gap)
      "#{gap["criterion"]}: #{gap["next_step"].to_s.strip}"
    end

    def publish_parent_dependencies!
      numbers = agent_run.issue.issue_dependencies.includes(:depends_on_issue).filter_map { |dependency| dependency.depends_on_issue&.github_number }
      return if numbers.empty?

      # Base the rewrite on the live GitHub body, not the local copy, so
      # human edits made since the last sync survive (same pattern as
      # CreateMultipleIssuesActivity#update_parent_issue).
      body = agent_run.project.client.issue(agent_run.project.full_name, agent_run.issue.github_number).body.to_s
      lines = new_dependency_lines(numbers, body)
      return if lines.empty?

      updated_body = append_dependency_lines(lines, body)
      agent_run.project.client.update_issue(agent_run.project.full_name, agent_run.issue.github_number, body: updated_body)
      agent_run.issue.update!(body: updated_body)
    end

    def new_dependency_lines(numbers, body)
      numbers.filter_map do |number|
        line = ProjectConventions::IssueDependencies.depends_on_line(project: agent_run.project, github_number: number, resolved: dependency_conventions)
        "- #{line}" unless body.match?(/\b#{Regexp.escape(line)}\b/)
      end
    end

    def append_dependency_lines(lines, body)
      heading = ProjectConventions::IssueDependencies.heading(project: agent_run.project, resolved: dependency_conventions)
      return insert_under_heading(lines, body, heading) if body.include?(heading)

      [ body, heading, lines.join("\n") ].reject(&:blank?).join("\n\n")
    end

    # The heading may sit mid-body with sections after it; insert the new
    # lines at the end of the heading's own section rather than at the very
    # end of the body, outside the section they belong to.
    def insert_under_heading(lines, body, heading)
      heading_start = body.index(heading)
      remainder = body[(heading_start + heading.length)..].to_s
      section, trailing = remainder.split(/(?=\n\s*#)/, 2)
      updated_section = [ section.rstrip, lines.join("\n") ].reject(&:blank?).join("\n")
      [ body[0...heading_start].rstrip, heading, updated_section, trailing.to_s.lstrip ]
        .reject(&:blank?).join("\n\n")
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
