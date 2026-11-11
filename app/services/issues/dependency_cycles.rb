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
    class CoverageUnavailable < StandardError; end

    Edge = Data.define(:id, :from_id, :to_id, :declaration_source, :declaration_url)

    Cycle = Data.define(:account, :issues, :path, :path_edges, :effective_edges, :downstream_issues, :detected_at,
      :occurrence, :visible_parent_project_ids) do
      def fingerprint
        Digest::SHA256.hexdigest(issues.map(&:id).sort.join(":"))[0, 20]
      end

      def id = "dependency_cycle:#{fingerprint}"
      def graph_revision = occurrence
      def project = issues.min_by { |issue| [ issue.project.owner, issue.project.repo, issue.github_number ] }.project
      def title = "Dependency cycle across #{issues.size} issue#{'s' unless issues.one?}"
      def summary
        count = downstream_issues.size
        "#{count} downstream open issue#{'s' unless count == 1} remain#{'s' if count == 1} held."
      end
      def project_ids = issues.map(&:project_id).uniq
      def visible_within?(visible_project_ids) = project_ids.all? { |project_id| visible_project_ids.include?(project_id) }
      def touches?(visible_project_ids) = project_ids.any? { |project_id| visible_project_ids.include?(project_id) }

      # The parent (umbrella) issue for a path/edge node, when one is linked
      # and its project is within the caller's authorized visibility. A nil
      # `visible_parent_project_ids` means the caller is not operator-scoped
      # (e.g. the reconciliation job) and every locally linked parent is
      # returned. @spec AUTO-PICK-QUEUE-020
      def umbrella_for(issue)
        parent = issue.parent_issue
        return nil unless parent
        return parent if visible_parent_project_ids.nil?
        return nil unless visible_parent_project_ids.include?(parent.project_id)

        parent
      end
    end

    def self.call(...) = new(...).call

    def self.cyclic_ids(node_ids:, edges:)
      node_ids = node_ids.to_set
      edges = edges.select { |from_id, to_id| node_ids.include?(from_id) && node_ids.include?(to_id) }
      components = GraphComponents.new(node_ids:, edges:).call
      self_edges = edges.select { |from_id, to_id| from_id == to_id }.map(&:first).to_set
      components.filter_map { |component| component if component.size > 1 || self_edges.include?(component.first) }
        .flatten.to_set
    end

    def initialize(account:)
      @account = account
    end

    def call
      return [] if nodes.empty?

      components.filter_map { |component| cycle_for(component) }
    rescue ActiveRecord::StatementInvalid => error
      raise CoverageUnavailable, error.message
    end

    private

    attr_reader :account

    def nodes
      @nodes ||= Issue.joins(:project).where(projects: { account_id: account.id }, github_state: "open")
        .where.not(paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
        .includes(:project, parent_issue: :project).index_by(&:id)
    end

    def edges
      @edges ||= IssueDependency.joins(:issue, :depends_on_issue)
        .where(issues: { project_id: account.projects.select(:id), github_state: "open" })
        .where(depends_on_issue: { github_state: "open" })
        .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .excluding_parent_references
        .pluck(:id, :issue_id, :depends_on_issue_id, :declaration_source, :declaration_url)
        .filter_map do |id, from, to, source, url|
          Edge.new(id:, from_id: from, to_id: to, declaration_source: source, declaration_url: url) if nodes.key?(from) && nodes.key?(to)
        end
    end

    def adjacency
      @adjacency ||= edges.group_by(&:from_id).transform_values { |group| group.map(&:to_id) }
    end

    # Kosaraju's two linear passes are intentionally iterative: a large legacy
    # import must not consume the Ruby stack while producing an operator alert.
    def components
      cyclic_ids = self.class.cyclic_ids(
        node_ids: nodes.keys,
        edges: edges.map { |edge| [ edge.from_id, edge.to_id ] }
      )
      cycle_edges = edges.filter_map do |edge|
        [ edge.from_id, edge.to_id ] if cyclic_ids.include?(edge.from_id) && cyclic_ids.include?(edge.to_id)
      end
      GraphComponents.new(node_ids: cyclic_ids, edges: cycle_edges).call
    end

    def cycle_for(component)
      ids = component.to_set
      path_ids = cycle_path(component.first, ids)
      effective_edges = edges.select { |edge| ids.include?(edge.from_id) && ids.include?(edge.to_id) }
      Cycle.new(account:, issues: component.map { |id| nodes.fetch(id) }.sort_by(&:id),
        path: path_ids.map { |id| nodes.fetch(id) },
        path_edges: path_ids.each_cons(2).map { |from, to| edge_between(from, to) },
        effective_edges:,
        downstream_issues: downstream_for(ids), detected_at: component.map { |id| nodes.fetch(id).updated_at }.min,
        occurrence: cycle_occurrence(effective_edges), visible_parent_project_ids: nil)
    end

    def edge_between(from_id, to_id)
      edge_index.fetch([ from_id, to_id ])
    end

    def edge_index
      @edge_index ||= edges.index_by { |edge| [ edge.from_id, edge.to_id ] }
    end

    def cycle_occurrence(effective_edges)
      digest = Digest::SHA256.hexdigest(effective_edges.map(&:id).sort.join(":"))
      "state:dependency_cycle:#{digest}"
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
      reverse = edges.group_by(&:to_id).transform_values { |group| group.map(&:from_id) }
      seen = cycle_ids.dup
      stack = cycle_ids.flat_map { |id| reverse.fetch(id, []) }
      until stack.empty?
        id = stack.pop
        next unless seen.add?(id)

        stack.concat(reverse.fetch(id, []))
      end
      (seen - cycle_ids).filter_map { |id| nodes[id] }
    end

    class GraphComponents
      def initialize(node_ids:, edges:)
        @node_ids = node_ids
        @forward = edges.group_by(&:first).transform_values { |group| group.map(&:last) }
        @reverse = edges.group_by(&:last).transform_values { |group| group.map(&:first) }
      end

      def call
        visited = Set.new
        finish_order.reverse_each.filter_map do |root|
          reachable_from(root, reverse, visited) if visited.add?(root)
        end
      end

      private

      attr_reader :node_ids, :forward, :reverse

      def finish_order
        visited = Set.new
        node_ids.each_with_object([]) do |root, order|
          finish_from(root, visited, order) unless visited.include?(root)
        end
      end

      def finish_from(root, visited, order)
        stack = [ [ root, false ] ]
        until stack.empty?
          id, expanded = stack.pop
          if expanded
            order << id
          elsif visited.add?(id)
            stack << [ id, true ]
            forward.fetch(id, []).reverse_each { |child| stack << [ child, false ] unless visited.include?(child) }
          end
        end
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
    end
  end
end
