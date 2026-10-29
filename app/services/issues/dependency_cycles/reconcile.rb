# frozen_string_literal: true

module Issues
  module DependencyCycles
    # Reconciles durable operator occurrences from the currently persisted,
    # effective blocking graph. It intentionally only describes a cycle; an
    # operator must decide which GitHub declaration to correct.
    # @spec DEPENDENCY-CYCLES-001 DEPENDENCY-CYCLES-002
    class Reconcile
      def self.call(...) = new(...).call

      def initialize(account:)
        @account = account
      end

      def call
        graph = effective_graph
        components = strongly_connected_components(graph).select { |members| members.size > 1 }
        reconcile_occurrences(components, graph)
      end

      private

      attr_reader :account

      def effective_graph
        edges.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |edge, graph|
          graph[edge[:from]] << edge
        end
      end

      def edges
        @edges ||= local_edges + resolved_external_edges
      end

      def local_edges
        IssueDependency.joins(issue: :project).joins(:depends_on_issue)
          .where(projects: { account_id: account.id }, issues: { github_state: "open" })
          .where(depends_on_issue: { github_state: "open" })
          .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
          .excluding_parent_references
          .pluck(:issue_id, :depends_on_issue_id)
          .map { |from, to| edge(from, to, "local dependency declaration") }
      end

      def resolved_external_edges
        IssueDependency.external_resolved_for_account(account.id).joins(:issue)
          .where(issues: { github_state: "open" })
          .where("issues.parent_issue_id IS DISTINCT FROM ext_issue.id")
          .where("ext_issue.github_state = 'open' AND ext_issue.paid_state NOT IN (?)", Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES)
          .pluck(:issue_id, Arel.sql("ext_issue.id"), :depends_on_owner, :depends_on_repo, :depends_on_number)
          .map { |from, to, owner, repo, number| edge(from, to, "#{owner}/#{repo}##{number}") }
      end

      def edge(from, to, provenance)
        { from:, to:, provenance: }
      end

      def strongly_connected_components(graph)
        index = 0
        indexes = {}
        lowlinks = {}
        stack = []
        on_stack = Set.new
        graph.keys.each_with_object([]) do |node, components|
          index = visit(node, graph, index, indexes, lowlinks, stack, on_stack, components) unless indexes.key?(node)
        end
      end

      def visit(node, graph, index, indexes, lowlinks, stack, on_stack, components)
        indexes[node] = lowlinks[node] = index
        index += 1
        stack << node
        on_stack << node
        graph.fetch(node, []).each do |edge|
          child = edge[:to]
          index = visit(child, graph, index, indexes, lowlinks, stack, on_stack, components) unless indexes.key?(child)
          lowlinks[node] = [ lowlinks[node], lowlinks[child] ].min if on_stack.include?(child)
        end
        components << pop_component(node, lowlinks, indexes, stack, on_stack) if lowlinks[node] == indexes[node]
        index
      end

      def pop_component(node, lowlinks, indexes, stack, on_stack)
        component = []
        loop do
          member = stack.pop
          on_stack.delete(member)
          component << member
          break if member == node
        end
        component
      end

      def reconcile_occurrences(components, graph)
        seen_keys = components.map do |members|
          key = cycle_key(members)
          occurrence = DependencyCycleOccurrence.find_or_initialize_by(account:, cycle_key: key)
          occurrence.assign_attributes(active: true, resolved_at: nil, last_detected_at: Time.current,
            details: details_for(members, graph))
          occurrence.save!
          key
        end
        DependencyCycleOccurrence.active.where(account:).where.not(cycle_key: seen_keys)
          .update_all(active: false, resolved_at: Time.current, updated_at: Time.current)
      end

      def cycle_key(members)
        Digest::SHA256.hexdigest(members.sort.join(","))
      end

      def details_for(members, graph)
        issues = Issue.where(id: members).includes(:project).index_by(&:id)
        path = cycle_path(members, graph)
        { "members" => members.sort, "cycle_path" => path.map { |edge|
          issue = issues.fetch(edge[:from]); target = issues.fetch(edge[:to])
          { "from" => issue.github_url, "from_label" => "#{issue.project.full_name}##{issue.github_number}",
            "to" => target.github_url, "to_label" => "#{target.project.full_name}##{target.github_number}",
            "provenance" => edge[:provenance] }
        }, "downstream_count" => downstream_count(members, graph),
          "project_id" => issues.values.min_by { |issue| [ issue.project.full_name, issue.github_number ] }.project_id,
          "project_ids" => issues.values.map(&:project_id).uniq.sort }
      end

      def cycle_path(members, graph)
        start = members.min
        find_cycle_path(start, start, members.to_set, graph, [], Set.new)
      end

      def find_cycle_path(start, current, members, graph, path, visited)
        graph.fetch(current, []).each do |edge|
          next unless members.include?(edge[:to])
          return path + [ edge ] if edge[:to] == start
          next if visited.include?(edge[:to])

          found = find_cycle_path(start, edge[:to], members, graph, path + [ edge ], visited | [ edge[:to] ])
          return found if found
        end
        nil
      end

      def downstream_count(members, graph)
        reverse = edges.each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |edge, map| map[edge[:to]] << edge[:from] }
        visited = Set.new(members)
        queue = members.dup
        until queue.empty?
          reverse.fetch(queue.shift, []).each { |id| queue << id if visited.add?(id) }
        end
        visited.size - members.size
      end
    end
  end
end
