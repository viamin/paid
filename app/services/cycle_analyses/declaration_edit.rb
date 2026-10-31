# frozen_string_literal: true

require "strscan"

module CycleAnalyses
  # Surgically removes or corrects one dependency reference inside a GitHub
  # issue body, touching nothing else. A target reference is only ever edited
  # when it resolves to exactly one line that contains no other reference —
  # anything less isolated is reported unresolved so the caller can hold the
  # repair instead of guessing at surrounding text (AUTO-PICK-QUEUE-023).
  class DeclarationEdit
    QUALIFIED_TOKEN = %r{[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+\#\d+}
    BARE_TOKEN = /(?<![a-zA-Z0-9._\/-])\#\d+/

    Outcome = Data.define(:status, :body) do
      def applied? = status == :applied
      def already_satisfied? = status == :already_satisfied
      def ambiguous? = status == :ambiguous
      def unresolved? = status == :unresolved
      def resolved? = applied? || already_satisfied?
    end

    def self.remove(body:, declaring_issue:, target_issue:, require_match: false)
      new(body:, declaring_issue:, target_issue:, require_match:).remove
    end

    def self.correct(body:, declaring_issue:, target_issue:, replacement_issue:, require_match: false)
      new(body:, declaring_issue:, target_issue:, require_match:).correct(replacement_issue)
    end

    # @param require_match [Boolean] when true, a target reference absent from
    #   the body is reported :unresolved rather than :already_satisfied. Set
    #   this when there is no persisted local provenance confirming the
    #   declaration was ever live, so a live miss cannot be assumed to be a
    #   prior successful edit (AUTO-PICK-QUEUE-022).
    def initialize(body:, declaring_issue:, target_issue:, require_match: false)
      @body = body.to_s
      @declaring_issue = declaring_issue
      @target_issue = target_issue
      @require_match = require_match
    end

    def remove
      index = sole_matching_line_index
      return missing_outcome if index == :none
      return Outcome.new(status: :ambiguous, body:) if index == :ambiguous

      lines = body.lines
      lines.delete_at(index)
      Outcome.new(status: :applied, body: lines.join)
    end

    def correct(replacement_issue)
      index = sole_matching_line_index
      return missing_outcome if index == :none
      return Outcome.new(status: :ambiguous, body:) if index == :ambiguous

      lines = body.lines
      line = lines[index]
      lines[index] = line.sub(matched_token(line), replacement_token(replacement_issue))
      Outcome.new(status: :applied, body: lines.join)
    end

    private

    attr_reader :body, :declaring_issue, :target_issue, :require_match

    def missing_outcome
      Outcome.new(status: require_match ? :unresolved : :already_satisfied, body:)
    end

    def sole_matching_line_index
      lines = body.lines
      referencing = lines.each_index.select { |i| tokens_in(lines[i]).any? { |token| token_matches_target?(token) } }
      return :none if referencing.empty?
      return :ambiguous if referencing.size > 1

      index = referencing.first
      return :ambiguous unless tokens_in(lines[index]).size == 1

      index
    end

    def matched_token(line) = tokens_in(line).first

    def tokens_in(line)
      found = []
      scanner = StringScanner.new(line.to_s)
      until scanner.eos?
        token = scanner.scan(QUALIFIED_TOKEN) || scanner.scan(BARE_TOKEN)
        if token
          found << token
        else
          scanner.getch
        end
      end
      found
    end

    def token_matches_target?(token)
      if token.include?("/")
        owner_repo, number = token.split("#")
        owner_repo.casecmp?(target_issue.project.full_name) && number.to_i == target_issue.github_number
      else
        same_project?(target_issue) && token.delete_prefix("#").to_i == target_issue.github_number
      end
    end

    def same_project?(issue) = issue.project_id == declaring_issue.project_id

    def replacement_token(replacement_issue)
      if same_project?(replacement_issue)
        "##{replacement_issue.github_number}"
      else
        "#{replacement_issue.project.full_name}##{replacement_issue.github_number}"
      end
    end
  end
end
