# frozen_string_literal: true

module Issues
  # Read-only, bounded ranking of dependency roots that can unlock current
  # partial-closeout work. It consumes the persisted effective dependency
  # graph and canonical auto-pick eligibility; it never syncs a provider or
  # asks an LLM while an Inbox detail is rendered.
  # @spec PARTIAL-CLOSEOUT-048
  class RootPrerequisiteRanking
    MAX_NODES = 500
    MAX_PATHS_PER_ROOT = 25
    MAX_RANKED_ROOTS = 5
    UNKNOWN_BLOCKER = :unknown_blocker

    Path = Data.define(:downstream_issue, :issues, :necessary, :completion_alone_makes_runnable, :stale)
    Ranking = Data.define(:root, :direct_reach, :transitive_reach, :paths, :actionable) do
      def total_reach = direct_reach + transitive_reach
    end
    Result = Data.define(:rankings, :exclusions) do
      include Enumerable

      def each(&) = rankings.each(&)
      def empty? = rankings.empty?
    end

    def self.call(...) = new(...).call

    def initialize(account:, queue_issue_ids:, visible_project_ids: nil)
      @account = account
      @queue_issue_ids = queue_issue_ids.to_set
      @visible_project_ids = (visible_project_ids || account.project_ids).to_set
    end

    def call
      return Result.new(rankings: [], exclusions: []) if queue_issue_ids.empty?

      load_graph
      Result.new(rankings: ranked_roots, exclusions: @exclusions)
    end

    private

    attr_reader :account, :queue_issue_ids, :visible_project_ids

    def load_graph
      @issues = {}
      @dependencies = []
      load_queue_ancestors
      @upstream = dependencies.group_by(&:first).transform_values { |edges| edges.map(&:last) }
      @downstream = dependencies.group_by(&:last).transform_values { |edges| edges.map(&:first) }
      @cyclic_ids = cycle_ids
      @external_by_issue = unresolved_external_by_issue
      @assessments = PartialCloseouts::Assessment.persisted_for(issues.values)
      @human_decision_ids = assessments.filter_map do |issue_id, assessment|
        issue_id if Array(assessment["gaps"]).any? { |gap| gap.is_a?(Hash) && gap["kind"] == "human" }
      end.to_set
      @exclusions = exclusion_rows
    end

    def load_queue_ancestors
      ancestor_ids = recursive_ancestor_ids
      loaded_ids = load_issues(ancestor_ids).map(&:id).to_set
      @unavailable_queue_issue_ids = queue_issue_ids - loaded_ids
      @dependencies = dependency_edges_from(loaded_ids).select { |_, parent_id| loaded_ids.include?(parent_id) }
    end

    def recursive_ancestor_ids
      ApplicationRecord.connection.select_values(recursive_ancestor_sql).map!(&:to_i)
    end

    def recursive_ancestor_sql
      <<~SQL.squish
        WITH RECURSIVE blocking_edges(issue_id, depends_on_issue_id) AS NOT MATERIALIZED (
          #{local_dependency_edge_scope.select(:issue_id, :depends_on_issue_id).to_sql}
          UNION ALL
          #{resolved_external_dependency_edge_scope.select(:issue_id, "ext_issue.id AS depends_on_issue_id").to_sql}
        ), ancestors(id) AS (
          SELECT unnest(ARRAY[#{queue_issue_ids.map { |id| Integer(id) }.join(", ")}]::bigint[])
          UNION
          SELECT blocking_edges.depends_on_issue_id
          FROM blocking_edges INNER JOIN ancestors ON blocking_edges.issue_id = ancestors.id
        )
        SELECT id FROM ancestors LIMIT #{MAX_NODES + 1}
      SQL
    end

    def load_issues(ids)
      return [] if ids.empty?

      remaining = MAX_NODES - issues.size
      records = blocking_issue_scope.where(id: ids).order(:id).limit(remaining + 1).to_a
      @graph_truncated = true if records.size > remaining
      records.first(remaining).each { |issue| issues[issue.id] = issue }
    end

    def blocking_issue_scope
      Issue.joins(:project).where(projects: { account_id: account.id }).includes(:project)
    end

    def dependency_edges_from(issue_ids)
      local_dependency_edges_from(issue_ids) + resolved_external_dependency_edges_from(issue_ids)
    end

    def local_dependency_edges_from(issue_ids)
      local_dependency_edge_scope(issue_ids).pluck(:issue_id, :depends_on_issue_id)
    end

    def local_dependency_edge_scope(issue_ids = nil)
      dependency_scope(issue_ids).where(depends_on_issue: { github_state: "open" })
        .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .or(deployment_dependency_scope(issue_ids))
    end

    def resolved_external_dependency_edges_from(issue_ids)
      resolved_external_dependency_edge_scope(issue_ids).pluck("issue_dependencies.issue_id", "ext_issue.id")
    end

    def resolved_external_dependency_edge_scope(issue_ids = nil)
      scope = IssueDependency.external_resolved_for_account(account.id).joins(issue: :project)
        .where(projects: { account_id: account.id })
        .where("issues.parent_issue_id IS DISTINCT FROM ext_issue.id")
        .where(blocking_external_dependency_condition)
      issue_ids ? scope.where(issue_id: issue_ids) : scope
    end

    def dependency_scope(issue_ids = nil)
      scope = IssueDependency.joins(:depends_on_issue, issue: :project).where(projects: { account_id: account.id })
        .excluding_parent_references
      issue_ids ? scope.where(issue_id: issue_ids) : scope
    end

    def deployment_dependency_scope(issue_ids)
      dependency_scope(issue_ids).where(requires_deployment: true)
        .where(depends_on_issue: { is_pull_request: true, deployed_at: nil })
        .where.not(depends_on_issue: { github_state: "open" })
    end

    def blocking_external_dependency_condition
      Issue.sanitize_sql_array([ <<~SQL.squish, Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES ])
        ext_issue.github_state = 'open' AND ext_issue.paid_state NOT IN (?)
      SQL
    end

    attr_reader :issues, :dependencies, :upstream, :downstream, :cyclic_ids, :external_by_issue,
      :human_decision_ids, :assessments

    def ranked_roots
      return [] if @graph_truncated

      rankings = candidate_roots.filter_map { |root| ranking_for(root) }.sort_by { |ranking|
        [ -ranking.total_reach, -ranking.direct_reach, ranking.root.github_number, ranking.root.id ]
      }.first(MAX_RANKED_ROOTS)
      load_actionable_root_ids(rankings.map(&:root))
      rankings = rankings.map { |ranking| ranking.with(actionable: actionable?(ranking.root)) }
      add_freshness(rankings)
    end

    def candidate_roots
      issues.values.select do |issue|
        visible_project_ids.include?(issue.project_id) && blocking_prerequisite?(issue) && upstream.fetch(issue.id, []).empty? &&
          !cyclic_ids.include?(issue.id) && !external_by_issue.key?(issue.id) && !human_decision_ids.include?(issue.id)
      end
    end

    def blocking_prerequisite?(issue)
      issue.github_state == "open" && !issue.paid_state.in?(Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
    end

    def ranking_for(root)
      path_ids = path_ids_from(root)
      return if path_ids.empty?

      direct_reach = path_ids.count { |ids| ids.size == 2 }
      paths = path_ids.first(MAX_PATHS_PER_ROOT).map { |ids| build_path(ids) }
      Ranking.new(root:, direct_reach:, transitive_reach: path_ids.size - direct_reach, paths:, actionable: nil)
    end

    def path_ids_from(root)
      found = {}
      visited = Set[root.id]
      stack = [ [ root.id, [ root.id ] ] ]
      until stack.empty?
        current_id, path_ids = stack.pop
        downstream.fetch(current_id, []).sort.reverse_each do |dependent_id|
          next unless visible_issue?(dependent_id)
          next if path_ids.include?(dependent_id) || excluded_blocker?(dependent_id)

          next_path = path_ids + [ dependent_id ]
          if queue_issue_ids.include?(dependent_id)
            found[dependent_id] ||= next_path
          end
          stack << [ dependent_id, next_path ] if visited.add?(dependent_id)
        end
      end
      found.values
    end

    def build_path(ids)
      downstream_issue = issues.fetch(ids.last)
      Path.new(
        downstream_issue:,
        issues: ids.map { |id| issues.fetch(id) },
        necessary: true,
        completion_alone_makes_runnable: all_blocking_roots_for(downstream_issue.id) == Set[ids.first],
        stale: nil
      )
    end

    def add_freshness(rankings)
      path_issues = rankings.flat_map(&:paths).map(&:downstream_issue).uniq
      evidence = Issues::CloseoutEvidence.results_for(path_issues)
      technical = TechnicalPrerequisites::Evidence.records_for_issues(path_issues)
      measurements = TrustedMeasurements::Evidence.records_for_issues(path_issues)
      stale_by_id = path_issues.to_h do |issue|
        assessment = PartialCloseouts::Assessment.call(issue, persisted_assessment: assessments.fetch(issue.id, {}),
          evidence: evidence.fetch(issue.id), technical_evidence: technical.fetch(issue.id),
          trusted_measurement_evidence: measurements.fetch(issue.id))
        [ issue.id, assessment.stale? ]
      end
      rankings.map { |ranking| ranking.with(paths: ranking.paths.map { |path| path.with(stale: stale_by_id.fetch(path.downstream_issue.id)) }) }
    end

    def all_blocking_roots_for(issue_id, seen = Set.new)
      return Set[UNKNOWN_BLOCKER] if !seen.add?(issue_id) || excluded_blocker?(issue_id)

      parents = upstream.fetch(issue_id, [])
      return Set[issue_id] if parents.empty?

      parents.each_with_object(Set.new) { |parent_id, roots| roots.merge(all_blocking_roots_for(parent_id, seen.dup)) }
    end

    def excluded_blocker?(issue_id)
      cyclic_ids.include?(issue_id) || external_by_issue.key?(issue_id) || human_decision_ids.include?(issue_id)
    end

    def actionable?(issue)
      @actionable_root_ids.include?(issue.id)
    end

    def load_actionable_root_ids(roots)
      @actionable_root_ids = roots.group_by(&:project).flat_map do |project, project_roots|
        Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(
          project, issue_ids: project_roots.map(&:id)
        ).pluck(:id)
      end.to_set
    end

    def cycle_ids
      Issues::DependencyCycles.cyclic_ids(node_ids: issues.keys, edges: dependencies)
    end

    def unresolved_external_by_issue
      IssueDependency.external_resolved_for_account(account.id).where(issue_id: issues.keys)
        .where("ext_project.id IS NULL OR ext_issue.id IS NULL")
        .pluck(:issue_id, :depends_on_owner, :depends_on_repo, :depends_on_number).group_by(&:first)
    end

    def exclusion_rows
      rows = cyclic_ids.filter_map { |id| { kind: "cycle", issue: issues[id] } if visible_issue?(id) }
      rows << { kind: "graph_coverage_truncated", issue: nil } if @graph_truncated
      unavailable_queue_issue_ids.each { |id| rows << { kind: "queue_issue_unavailable", issue: nil, issue_id: id } }
      external_by_issue.each_key { |id| rows << { kind: "unresolved_external", issue: issues[id] } if visible_issue?(id) }
      human_decision_ids.each { |id| rows << { kind: "human_decision", issue: issues[id] } if visible_issue?(id) }
      rows
    end

    def visible_issue?(id) = visible_project_ids.include?(issues.fetch(id).project_id)

    def unavailable_queue_issue_ids = @unavailable_queue_issue_ids || Set.new
  end
end
