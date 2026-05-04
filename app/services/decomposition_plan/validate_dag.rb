# frozen_string_literal: true

module DecompositionPlan
  # Validates that a decomposition plan's dependency graph is a valid DAG.
  #
  # Checks:
  # 1. No cycles exist (topological sort succeeds)
  # 2. Every node is reachable from at least one leaf (no orphans)
  # 3. All dependency references point to valid task indices
  #
  # @example
  #   result = DecompositionPlan::ValidateDag.call(tasks: tasks)
  #   result.valid?       # => true
  #   result.sorted_indices # => [0, 2, 1, 3]  (topological order)
  class ValidateDag
    attr_reader :tasks

    def initialize(tasks:)
      @tasks = Array(tasks)
    end

    def self.call(...)
      new(...).call
    end

    def call
      return Result.new(valid: true, sorted_indices: [], errors: []) if tasks.empty?

      errors = []
      errors.concat(validate_references)
      return Result.new(valid: false, sorted_indices: [], errors: errors) if errors.any?

      sorted = topological_sort
      if sorted.nil?
        errors << "dependency graph contains a cycle"
        return Result.new(valid: false, sorted_indices: [], errors: errors)
      end

      unreachable = find_unreachable_from_leaves
      if unreachable.any?
        labels = unreachable.map { |i| "#{i} (#{tasks[i][:title]})" }.join(", ")
        errors << "tasks not reachable from any leaf node: #{labels}"
      end

      Result.new(valid: errors.empty?, sorted_indices: sorted, errors: errors)
    end

    private

    def validate_references
      errors = []
      valid_range = 0...tasks.size

      tasks.each_with_index do |task, index|
        Array(task[:deps]).each do |dep|
          unless valid_range.cover?(dep)
            errors << "task #{index} (#{task[:title]}) depends on invalid index #{dep}"
          end
          if dep == index
            errors << "task #{index} (#{task[:title]}) depends on itself"
          end
        end
      end

      errors
    end

    # Kahn's algorithm for topological sort.
    # Returns sorted indices or nil if a cycle is detected.
    def topological_sort
      n = tasks.size
      in_degree = Array.new(n, 0)
      adjacency = Array.new(n) { [] }

      tasks.each_with_index do |task, index|
        Array(task[:deps]).each do |dep|
          adjacency[dep] << index
          in_degree[index] += 1
        end
      end

      queue = (0...n).select { |i| in_degree[i].zero? }
      sorted = []

      until queue.empty?
        node = queue.shift
        sorted << node

        adjacency[node].each do |neighbor|
          in_degree[neighbor] -= 1
          queue << neighbor if in_degree[neighbor].zero?
        end
      end

      sorted.size == n ? sorted : nil
    end

    # A node is "reachable from a leaf" if there exists a path from some leaf
    # (a node with no dependencies) to that node following dependency edges
    # forward. In practice every node should be downstream of at least one leaf.
    def find_unreachable_from_leaves
      n = tasks.size
      adjacency = Array.new(n) { [] }

      tasks.each_with_index do |task, index|
        Array(task[:deps]).each do |dep|
          adjacency[dep] << index
        end
      end

      leaves = (0...n).select { |i| Array(tasks[i][:deps]).empty? }
      visited = Array.new(n, false)
      stack = leaves.dup

      while (node = stack.pop)
        next if visited[node]
        visited[node] = true
        adjacency[node].each { |neighbor| stack << neighbor }
      end

      (0...n).reject { |i| visited[i] }
    end

    class Result
      attr_reader :sorted_indices, :errors

      def initialize(valid:, sorted_indices:, errors:)
        @valid = valid
        @sorted_indices = sorted_indices.freeze
        @errors = errors.freeze
      end

      def valid?
        @valid
      end
    end
  end
end
