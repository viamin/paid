# frozen_string_literal: true

module CycleRepairs
  # Compares the live effective graph minus one repaired edge against the
  # occurrence's members. A single-edge removal may only claim to resolve the
  # occurrence when no member can still reach itself, so multi-edge strongly
  # connected groups are refused instead of half-repaired
  # (AUTO-PICK-QUEUE-018).
  # @spec AUTO-PICK-QUEUE-021
  class PostRemovalGraph
    class << self
      def acyclic_after_removal?(cycle:, edge:)
        adjacency = IssueDependency.account_adjacency(cycle.account).transform_values(&:dup)
        (adjacency[edge.from_id] || []).delete(edge.to_id)
        cycle.issues.map(&:id).none? { |member| reaches_itself?(member, adjacency) }
      end

      private

      def reaches_itself?(member, adjacency)
        visited = Set.new
        stack = adjacency.fetch(member, []).dup
        until stack.empty?
          id = stack.pop
          return true if id == member

          next unless visited.add?(id)

          stack.concat(adjacency.fetch(id, []))
        end
        false
      end
    end
  end
end
