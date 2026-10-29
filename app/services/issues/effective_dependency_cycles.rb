# frozen_string_literal: true

module Issues
  # The scheduler's dependency interpretation, projected as an account-scoped
  # graph.  Keeping this projection here prevents recovery UI from treating a
  # parent reference, an agent-completed issue, or an unresolved remote ref as
  # a cycle when admission does not.
  # @spec DEPENDENCY-CYCLE-001
  class EffectiveDependencyCycles
    Edge = Struct.new(:from, :to, :dependency, keyword_init: true)
    Cycle = Struct.new(:issues, :edges, :downstream_issues, :key, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(account:, projects: nil)
      @account = account
      @projects = projects
    end

    def call
      components.filter_map { |component| cycle_for(component) }
    end

    private

    attr_reader :account, :projects

    def edges
      @edges ||= begin
        scope = IssueDependency.joins(issue: :project)
          .where(projects: { account_id: account.id })
          .includes(issue: :project, depends_on_issue: :project)
        scope.filter_map { |dependency| edge_for(dependency) }
      end
    end

    def edge_for(dependency)
      target = dependency.depends_on_issue || resolved_external_target(dependency)
      return unless target && blocking_target?(target)
      return if dependency.issue.parent_issue_id == target.id

      Edge.new(from: dependency.issue, to: target, dependency: dependency)
    end

    def resolved_external_target(dependency)
      return unless dependency.external?

      external_targets[[ dependency.depends_on_owner, dependency.depends_on_repo, dependency.depends_on_number ]]
    end

    def external_targets
      @external_targets ||= Issue.joins(:project).where(projects: { account_id: account.id })
        .includes(:project).each_with_object({}) do |issue, targets|
          targets[[ issue.project.owner.downcase, issue.project.repo.downcase, issue.github_number ]] = issue
        end
    end

    def blocking_target?(issue)
      issue.github_state == "open" && !Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES.include?(issue.paid_state)
    end

    # Tarjan's algorithm returns each strongly connected component once.
    def components
      @index = 0
      @indices = {}
      @lowlinks = {}
      @stack = []
      @on_stack = Set.new
      nodes.each_with_object([]) { |node, result| strong_connect(node, result) }
    end

    def nodes
      edges.flat_map { |edge| [ edge.from, edge.to ] }.uniq { |issue| issue.id }
    end

    def strong_connect(node, result)
      @indices[node.id] = @lowlinks[node.id] = @index
      @index += 1
      @stack << node
      @on_stack << node.id
      outgoing(node).each do |edge|
        visit_edge(node, edge, result)
      end
      result << pop_component(node) if @lowlinks[node.id] == @indices[node.id]
    end

    def visit_edge(node, edge, result)
      target = edge.to
      if !@indices.key?(target.id)
        strong_connect(target, result)
        @lowlinks[node.id] = [ @lowlinks[node.id], @lowlinks[target.id] ].min
      elsif @on_stack.include?(target.id)
        @lowlinks[node.id] = [ @lowlinks[node.id], @indices[target.id] ].min
      end
    end

    def pop_component(root)
      component = []
      loop do
        node = @stack.pop
        @on_stack.delete(node.id)
        component << node
        break if node.id == root.id
      end
      component
    end

    def outgoing(issue) = edges.select { |edge| edge.from.id == issue.id }

    def cycle_for(component)
      component_ids = component.map(&:id).to_set
      component_edges = edges.select { |edge| component_ids.include?(edge.from.id) && component_ids.include?(edge.to.id) }
      return if component.size == 1 && component_edges.none? { |edge| edge.from.id == edge.to.id }

      ordered = cycle_path(component.min_by(&:id), component_ids)
      Cycle.new(
        issues: component.sort_by(&:id), edges: ordered,
        downstream_issues: downstream(component_ids),
        key: component_ids.to_a.sort.join("-")
      )
    end

    def cycle_path(start, component_ids)
      path = []
      seen = {}
      current = start
      loop do
        edge = outgoing(current).select { |candidate| component_ids.include?(candidate.to.id) }.min_by { |candidate| [ candidate.to.id, candidate.dependency.id ] }
        break unless edge
        path << edge
        return path if edge.to.id == start.id
        return path if seen[edge.to.id]

        seen[current.id] = true
        current = edge.to
      end
      path
    end

    def downstream(component_ids)
      reverse = edges.group_by { |edge| edge.to.id }
      found = Set.new(component_ids)
      queue = component_ids.to_a
      until queue.empty?
        current = queue.shift
        Array(reverse[current]).each do |edge|
          next unless found.add?(edge.from.id)

          queue << edge.from.id
        end
      end
      Issue.where(id: found - component_ids, github_state: "open").to_a
    end
  end
end
