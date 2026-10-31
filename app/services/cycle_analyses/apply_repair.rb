# frozen_string_literal: true

module CycleAnalyses
  # Applies one obvious-correction candidate (CycleAnalyses::ObviousCorrection)
  # to GitHub, re-verifying every precondition against freshly fetched data
  # before writing anything, and confirming the persisted effective graph is
  # acyclic before reporting success (AUTO-PICK-QUEUE-022 AUTO-PICK-QUEUE-023).
  class ApplyRepair
    LOCK_NAMESPACE = 4824

    Result = Data.define(:status, :applied_changes, :message) do
      def success? = status == :repaired
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, candidate:, snapshot:, actor:)
      @agent_run = agent_run
      @candidate = candidate
      @snapshot = snapshot
      @actor = actor
    end

    def call
      return unauthorized_result unless authorized?

      lock_account!
      fresh_edges = fetch_fresh_edges
      return fresh_edges if fresh_edges.is_a?(Result)
      return stale_result("Cycle occurrence is no longer present.") unless fresh_cycle
      return stale_result("Effective dependency graph changed since analysis.") unless graph_unchanged?
      return provenance_result unless changes_still_valid?(fresh_edges)
      return verification_failed_result unless resulting_graph_acyclic?(fresh_edges)

      plan = build_plan(fresh_edges)
      return declaration_not_isolated_result unless plan

      outcome = apply_plan!(plan)
      return outcome if outcome.is_a?(Result)

      confirm!(outcome)
    rescue GithubClient::Error => error
      Result.new(status: :write_failed, applied_changes: [], message: "GitHub refused the repair: #{error.message}")
    end

    private

    attr_reader :agent_run, :candidate, :snapshot, :actor, :fresh_cycle

    def account = agent_run.project.account

    def changes = candidate.fetch("declaration_changes")

    def authorized?
      represented_projects.size == snapshot.fetch("project_ids").size &&
        represented_projects.all? { |project| ProjectPolicy.new(actor, project).run_agent? } &&
        declaring_projects.all? { |project| ProjectPolicy.new(actor, project).manage_issues? }
    end

    def declaring_projects
      @declaring_projects ||= Project.joins(:issues).where(issues: { id: changes.map { |change|
        snapshot.fetch("effective_edges").find { |edge| edge.fetch("id") == change.fetch("edge_id") }.fetch("from_issue_id")
      } }).distinct
    end

    def represented_projects
      @represented_projects ||= Project.where(id: snapshot.fetch("project_ids"))
    end

    def lock_account!
      AgentRun.connection.exec_query(
        AgentRun.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", LOCK_NAMESPACE, account.id ])
      )
    end

    def fetch_fresh_edges
      cycles = Issues::DependencyCycles.call(account:)
      @fresh_cycle = cycles.find { |cycle| cycle.fingerprint == snapshot.fetch("fingerprint") }
      fresh_cycle&.effective_edges || []
    rescue Issues::DependencyCycles::CoverageUnavailable
      Result.new(status: :verification_unavailable, applied_changes: [],
        message: "Could not verify the current dependency graph; retry later.")
    end

    def graph_unchanged? = fresh_cycle.occurrence == snapshot.fetch("occurrence")

    def fresh_edges_by_id(fresh_edges) = fresh_edges.index_by(&:id)

    # Missing persisted provenance is not, by itself, a reason to abort: the
    # live body lookup below (DeclarationEdit, via build_plan) is what
    # actually locates and verifies the declaration. A re-fetched source of
    # "issue_comment" is the only provenance value that disqualifies, since
    # writes only ever touch issue bodies.
    def changes_still_valid?(fresh_edges)
      index = fresh_edges_by_id(fresh_edges)
      changes.all? do |change|
        edge = index[change.fetch("edge_id")]
        next false unless edge && writable_source?(edge.declaration_source)
        next true unless change.fetch("action") == "correct"

        change.fetch("replacement").fetch("from_issue_id") == edge.from_id
      end
    end

    def writable_source?(source) = source.nil? || source == "issue_body"

    def resulting_graph_acyclic?(fresh_edges)
      issue_ids = fresh_cycle.issues.map(&:id)
      changes_by_edge_id = changes.index_by { |change| change.fetch("edge_id") }
      resulting_edges = fresh_edges.filter_map { |edge| apply_change_to_edge(edge, changes_by_edge_id) }
      AcyclicGraph.call(issue_ids:, edges: resulting_edges)
    end

    def apply_change_to_edge(edge, changes_by_edge_id)
      change = changes_by_edge_id[edge.id]
      return { "from_issue_id" => edge.from_id, "to_issue_id" => edge.to_id } unless change
      return nil if change.fetch("action") == "remove"

      change.fetch("replacement")
    end

    def build_plan(fresh_edges)
      index = fresh_edges_by_id(fresh_edges)
      groups = changes.group_by { |change| index.fetch(change.fetch("edge_id")).from_id }
      plan = {}
      groups.each do |declaring_issue_id, group_changes|
        declaring_issue = Issue.find(declaring_issue_id)
        entry = plan_entry_for(declaring_issue, group_changes, index)
        return nil unless entry

        plan[declaring_issue_id] = entry
      end
      plan
    end

    def plan_entry_for(declaring_issue, group_changes, index)
      body = fetch_remote_body(declaring_issue)
      changed = false
      group_changes.each do |change|
        edge = index.fetch(change.fetch("edge_id"))
        outcome = apply_single_change(declaring_issue, body, change, edge)
        return nil unless outcome.resolved?

        body = outcome.body
        changed ||= outcome.applied?
      end
      { declaring_issue:, body:, changed: }
    end

    # An edge with no persisted local provenance has no record confirming
    # the declaration was ever live, so a miss here cannot be assumed to be
    # a prior successful edit the way it can for a known-provenance edge —
    # require_match makes that miss :unresolved rather than :already_satisfied.
    def apply_single_change(declaring_issue, body, change, edge)
      target_issue = Issue.find(edge.to_id)
      require_match = edge.declaration_source.nil?
      if change.fetch("action") == "remove"
        DeclarationEdit.remove(body:, declaring_issue:, target_issue:, require_match:)
      else
        replacement_issue = Issue.find(change.fetch("replacement").fetch("to_issue_id"))
        DeclarationEdit.correct(body:, declaring_issue:, target_issue:, replacement_issue:, require_match:)
      end
    end

    def fetch_remote_body(issue)
      client = github_client_for(issue)
      client.issue(issue.project.full_name, issue.github_number).body.to_s
    end

    def github_client_for(issue)
      issue.project.client || raise(GithubClient::Error, "GitHub access is not configured for this project.")
    end

    def apply_plan!(plan)
      applied = []
      plan.each_value do |entry|
        write_declaration!(entry[:declaring_issue], entry[:body]) if entry[:changed]
        synchronize_from_github!(entry[:declaring_issue])
        applied << entry[:declaring_issue].id if entry[:changed]
      end
      applied
    rescue GithubClient::Error => error
      Result.new(status: :write_failed, applied_changes: applied,
        message: "GitHub declaration write failed after applying #{applied.size} of #{plan.size} change(s): #{error.message}")
    end

    def write_declaration!(issue, body)
      client = github_client_for(issue)
      client.update_issue(issue.project.full_name, issue.github_number, body:)
    end

    # Only the re-fetched GitHub body can update the persisted graph. This
    # keeps a successful write from being mistaken for synchronization and
    # prevents a local-only parse from making an Inbox occurrence disappear.
    def synchronize_from_github!(issue)
      remote_issue = github_client_for(issue).issue(issue.project.full_name, issue.github_number)
      body = remote_issue.body.to_s
      issue.update!(body:)
      Issues::ParseDependencies.call(issue:, body:, comments: trusted_comments(issue), reconcile: false)
    end

    def trusted_comments(issue)
      client = issue.project.client
      return [] unless client

      client.recent_issue_comments(issue.project.full_name, issue.github_number)
        .select { |comment| issue.project.trusted_github_user?(comment.user&.login) }
    end

    def confirm!(applied)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)
      still_cyclic = Issues::DependencyCycles.call(account:).any? { |cycle| cycle.fingerprint == snapshot.fetch("fingerprint") }
      record_audit!(applied, confirmed: !still_cyclic)
      if still_cyclic
        Result.new(status: :still_cyclic, applied_changes: applied,
          message: "Declaration edit applied but the group remains cyclic; it is held for manual review.")
      else
        Result.new(status: :repaired, applied_changes: applied,
          message: "Dependency cycle repaired and confirmed acyclic.")
      end
    rescue Issues::DependencyCycles::CoverageUnavailable
      record_audit!(applied, confirmed: nil)
      Result.new(status: :confirmation_unavailable, applied_changes: applied,
        message: "Declaration edit applied; synchronization confirmation is temporarily unavailable.")
    end

    def record_audit!(applied, confirmed:)
      Audit::RecordEvent.call(
        action: "dependency_cycle.repaired",
        actor:,
        subject: agent_run,
        account:,
        metadata: {
          occurrence: snapshot.fetch("occurrence"),
          fingerprint: snapshot.fetch("fingerprint"),
          declaration_changes: changes,
          applied_issue_ids: applied,
          confirmed_acyclic: confirmed
        }
      )
    end

    def unauthorized_result
      Result.new(status: :unauthorized, applied_changes: [],
        message: "Run authority is required for every represented project before a repair can be applied.")
    end

    def stale_result(message) = Result.new(status: :stale, applied_changes: [], message:)

    def provenance_result
      Result.new(status: :provenance_unavailable, applied_changes: [],
        message: "Declaration provenance is no longer available for the proposed change.")
    end

    def verification_failed_result
      Result.new(status: :verification_failed, applied_changes: [],
        message: "The proposed change no longer resolves to an acyclic graph.")
    end

    def declaration_not_isolated_result
      Result.new(status: :declaration_not_isolated, applied_changes: [],
        message: "The declaration could not be unambiguously located in the issue body.")
    end
  end
end
