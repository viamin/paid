# frozen_string_literal: true

module Issues
  # Checks the account-local blocking graph before an IssueDependency is saved.
  # Parent references are intentionally omitted: they are contextual links, not
  # prerequisites (AUTO-PICK-QUEUE-009).
  # @spec DEPENDENCY-DECLARATIONS-008
  class DependencyCycle
    Result = Data.define(:path) do
      def cycle? = path.present?
    end

    def self.call(...) = new(...).call

    def initialize(dependency)
      @dependency = dependency
    end

    def call
      return Result.new(path: nil) unless dependency.issue && target_issue
      return Result.new(path: nil) if parent_reference?

      lock_account!
      adjacency = IssueDependency.account_adjacency(dependency.issue.project.account)
      resolved_external_edges.each { |from_id, to_id| (adjacency[from_id] ||= []) << to_id }
      adjacency[dependency.issue_id] = proposed_targets
      Result.new(path: path_from(target_issue.id, dependency.issue_id, adjacency))
    end

    private

    attr_reader :dependency

    def parent_reference?
      dependency.issue.parent_issue_id == target_issue.id
    end

    def proposed_targets
      existing = dependency.issue.issue_dependencies.where.not(id: dependency.id).where.not(depends_on_issue_id: nil)
        .where.not(depends_on_issue_id: dependency.issue.parent_issue_id).pluck(:depends_on_issue_id)
      existing | [ target_issue.id ]
    end

    def target_issue
      return dependency.depends_on_issue if dependency.local?
      return unless dependency.external?

      @target_issue ||= Issue.joins(:project)
        .where(projects: { account_id: dependency.issue.project.account_id })
        .where("LOWER(projects.owner) = ? AND LOWER(projects.repo) = ?", dependency.depends_on_owner, dependency.depends_on_repo)
        .find_by(github_number: dependency.depends_on_number)
    end

    def resolved_external_edges
      IssueDependency.external_resolved_for_account(dependency.issue.project.account_id)
        .where.not(id: dependency.id)
        .pluck("issue_dependencies.issue_id", "ext_issue.id")
        .select { |_from_id, to_id| to_id.present? }
    end

    def lock_account!
      IssueDependency.connection.exec_query(
        IssueDependency.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", 4756, dependency.issue.project.account_id ])
      )
    end

    def path_from(start_id, target_id, adjacency)
      queue = [ [ start_id, [ start_id ] ] ]
      visited = Set.new

      until queue.empty?
        current_id, path = queue.shift
        next unless visited.add?(current_id)

        return [ dependency.issue_id ] + path if current_id == target_id

        (adjacency[current_id] || []).each { |next_id| queue << [ next_id, path + [ next_id ] ] }
      end
    end
  end
end
