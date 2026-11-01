# frozen_string_literal: true

module CycleRepairs
  # Locates the single live body line declaring one dependency edge using the
  # same whole-body, section-aware parsing as Issues::ParseDependencies, so a
  # canonical "## Dependencies" list item and an inline "Depends on #N"
  # phrase both match while Child Issues content never does. A line counts as
  # the declaration only when deleting exactly that line removes precisely the
  # target declaration and preserves every other declared reference, which
  # rejects bundled refs ("- #101 #102"), duplicate declarations, and heading
  # lines whose removal would widen a dependency section.
  # @spec AUTO-PICK-QUEUE-021
  class DeclarationMatch
    Result = Data.define(:status, :message, :edited_body, :declaration) do
      def removable? = status == :removed
    end

    def self.call(...) = new(...).call

    def initialize(body:, from_issue:, to_issue:)
      @body = body.to_s
      @from_issue = from_issue
      @to_issue = to_issue
    end

    def call
      return missing if target_keys.disjoint?(baseline_keys)

      declaring_lines = lines.select { |line| declares_target_ref?(line) }
      return ambiguous("multiple lines declare the dependency") if declaring_lines.size > 1
      return ambiguous("the declaration spans a multi-line list item") if declaring_lines.empty?

      candidate = candidate_at(lines.index(declaring_lines.first))
      return ambiguous("the declaration is bundled with other references on one line") unless candidate

      Result.new(status: :removed, message: nil, edited_body: candidate.fetch(:edited_body),
        declaration: candidate.fetch(:declaration))
    end

    private

    attr_reader :body, :from_issue, :to_issue

    def missing
      Result.new(status: :missing, edited_body: nil, declaration: nil, message:
        "The dependency is no longer declared by the live issue body; let synchronization reconcile the occurrence.")
    end

    def ambiguous(reason)
      Result.new(status: :ambiguous, edited_body: nil, declaration: nil, message:
        "The live declaration is ambiguous (#{reason}); edit the issue body on GitHub instead.")
    end

    def candidate_at(index)
      edited_keys = declared_keys(body_without_line(index))
      removed_keys = baseline_keys - edited_keys
      return nil unless (edited_keys - baseline_keys).empty? && removed_keys == (target_keys & baseline_keys)

      { edited_body: body_without_line(index), declaration: lines[index].strip }
    end

    # Only a line that itself carries the target reference can be the removed
    # declaration. Without this guard a section heading would qualify, because
    # deleting it stops the whole section from parsing, which would silently
    # drop every declaration under it.
    def declares_target_ref?(line)
      line.match?(/##{to_issue.github_number}(?!\d)/i) ||
        line.match?(%r{#{Regexp.escape(to_issue.project.owner)}/#{Regexp.escape(to_issue.project.repo)}\##{to_issue.github_number}(?!\d)}i)
    end

    def baseline_keys
      @baseline_keys ||= declared_keys(body)
    end

    def declared_keys(text)
      local, cross = Issues::ParseDependencies.extract(body: text)
      Set.new(local.keys.map { |number| [ :local, number ] } + cross.keys.map { |key| [ :cross, *key ] })
    end

    # The declaration forms that reference the target issue: the fully
    # qualified owner/repo#N form always, plus the bare #N form when the
    # target lives in the declaring issue's own project.
    def target_keys
      keys = [ [ :cross, to_issue.project.owner.downcase, to_issue.project.repo.downcase, to_issue.github_number ] ]
      keys << [ :local, to_issue.github_number ] if to_issue.project_id == from_issue.project_id
      @target_keys ||= Set.new(keys)
    end

    def lines
      @lines ||= body.each_line.to_a
    end

    def body_without_line(index)
      lines.reject.with_index { |_line, line_index| line_index == index }.join
    end
  end
end
