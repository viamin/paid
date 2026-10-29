# frozen_string_literal: true

module Issues
  # Finds cycles in the persisted, effective dependency graph.  Parsing rejects
  # new cycles, but imports made before that guard (and temporarily unresolved
  # cross-repository references) can leave durable deadlocks behind.
  #
  # The graph deliberately mirrors Issue#blocking_issues: only open targets
  # which are not parked/completed and child-to-parent contextual references
  # participate.  Resolved cross-project references have already been folded
  # into local IssueDependency rows by ParseDependencies.
  # @spec AUTO-PICK-QUEUE-014
  class DependencyCycles
    Cycle = Data.define(:account, :issues, :path, :downstream_issues, :detected_at) do
      def fingerprint
        Digest::SHA256.hexdigest(issues.map(&:id).sort.join(":"))[0, 20]
      end

      def id = "dependency_cycle:#{fingerprint}"
      def project = issues.min_by { |issue| [ issue.project.owner, issue.project.repo, issue.github_number ] }.project
      def title = "Dependency cycle across #{issues.size} issue#{'s' unless issues.one?}"
      def summary = "#{downstream_issues.size} downstream open issue#{'s' unless downstream_issues.one?} remain held."
    end

    def self.call(...) = new(...).call

    def initialize(account:)
      @account = account
    end

    def call
      return [] if nodes.empty?

      components.filter_map { |component| cycle_for(component) }
    rescue ActiveRecord::StatementInvalid => error
      Rails.logger.warn(message: "dependency_cycles.coverage_unavailable", account_id: account.id,
        error_class: error.class.name, error: error.message)
      []
    end

    private

    attr_reader :account

    def nodes
      @nodes ||= Issue.joins(:project).where(projects: { account_id: account.id }, github_state: "open")
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES).includes(:project).index_by(&:id)
    end

    def edges
      @edges ||= IssueDependency.joins(:issue, :depends_on_issue)
        .where(issues: { project_id: account.projects.select(:id), github_state: "open" })
        .where(depends_on_issue: { github_state: "open" })
        .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .excluding_parent_references
        .pluck(:issue_id, :depends_on_issue_id)
        .select { |from, to| nodes.key?(from) && nodes.key?(to) }
    end

    def adjacency
      @adjacency ||= edges.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    # Kosaraju's two linear passes are intentionally iterative: a large legacy
    # import must not consume the Ruby stack while producing an operator alert.
    def components
      order = finish_order(adjacency)
      reverse = edges.group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
      visited = Set.new
      order.reverse_each.each_with_object([]) do |id, result|
        next unless visited.add?(id)

        component = reachable_from(id, reverse, visited)
        result << component if component.size > 1 || adjacency.fetch(id, []).include?(id)
      end
    end

    def finish_order(graph)
      visited = Set.new
      order = []
      nodes.each_key do |root|
        next if visited.include?(root)

        stack = [ [ root, false ] ]
        until stack.empty?
          id, expanded = stack.pop
          if expanded
            order << id
          elsif visited.add?(id)
            stack << [ id, true ]
            graph.fetch(id, []).reverse_each { |child| stack << [ child, false ] unless visited.include?(child) }
          end
        end
      end
      order
    end

    def reachable_from(root, graph, visited)
      result = [ root ]
      stack = graph.fetch(root, []).dup
      until stack.empty?
        id = stack.pop
        next unless visited.add?(id)

        result << id
        stack.concat(graph.fetch(id, []))
      end
      result
    end

    def cycle_for(component)
      ids = component.to_set
      path_ids = cycle_path(component.first, ids)
      Cycle.new(account:, issues: component.map { |id| nodes.fetch(id) }.sort_by(&:id),
        path: path_ids.map { |id| nodes.fetch(id) },
        downstream_issues: downstream_for(ids), detected_at: component.map { |id| nodes.fetch(id).updated_at }.min)
    end

    def cycle_path(start, ids)
      stack = [ [ start, [ start ] ] ]
      until stack.empty?
        id, path = stack.pop
        adjacency.fetch(id, []).each do |child|
          next unless ids.include?(child)
          return path + [ start ] if child == start
          next if path.include?(child)

          stack << [ child, path + [ child ] ]
        end
      end
      [ start, start ]
    end

    def downstream_for(cycle_ids)
      reverse = edges.group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
      seen = cycle_ids.dup
      stack = cycle_ids.flat_map { |id| reverse.fetch(id, []) }
      until stack.empty?
        id = stack.pop
        next unless seen.add?(id)

        stack.concat(reverse.fetch(id, []))
      end
      (seen - cycle_ids).filter_map { |id| nodes[id] }
    end
  end
end
