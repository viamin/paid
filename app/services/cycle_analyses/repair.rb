# frozen_string_literal: true

module CycleAnalyses
  # Applies one already-reviewed declaration removal. The service deliberately
  # owns the final authority, graph, and live-source checks so callers cannot
  # turn a stale analysis into an arbitrary GitHub body write.
  class Repair
    Result = Data.define(:status, :message) do
      def success? = status == :applied
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, candidate:, actor:)
      @agent_run = agent_run
      @candidate = candidate
      @actor = actor
    end

    # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
    def call
      return needs_operator_action("Only a completed cycle analysis can be repaired.") unless agent_run.successful?
      return unauthorized unless authorized?
      return stale unless current_cycle

      changes = candidate.fetch("declaration_changes")
      return needs_operator_action("The selected analysis candidate is not acyclic.") unless candidate["acyclic"] == true
      return needs_operator_action("Only declaration removals can be repaired automatically.") unless removable?(changes)

      changes.each do |change|
        result = apply_removal(change)
        return result unless result.success?
      end
      Result.new(status: :applied, message: "Dependency declaration repair applied.")
    rescue KeyError, ActiveRecord::RecordNotFound => error
      needs_operator_action("Cycle repair evidence is incomplete: #{error.message}.")
    rescue GithubClient::Error => error
      needs_operator_action("GitHub rejected the dependency repair: #{error.message}.")
    end

    private

    attr_reader :actor, :agent_run, :candidate

    def snapshot = agent_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)

    def authorized?
      declaration_issue_ids.all? do |issue_id|
        issue = Issue.find(issue_id)
        ProjectPolicy.new(actor, issue.project).manage_issues?
      end
    end

    def declaration_issue_ids
      snapshot.fetch("effective_edges").filter_map do |edge|
        change_ids.include?(edge.fetch("id")) ? edge.fetch("from_issue_id") : nil
      end
    end

    def change_ids = candidate.fetch("declaration_changes").filter_map { |change| change["edge_id"] }

    def current_cycle
      Issues::DependencyCycles.call(account: agent_run.project.account).find do |cycle|
        cycle.occurrence == snapshot.fetch("occurrence") && cycle.fingerprint == snapshot.fetch("fingerprint")
      end
    end

    def removable?(changes)
      changes.any? && changes.all? { |change| change["action"] == "remove" && change["edge_id"].is_a?(Integer) }
    end

    def apply_removal(change)
      edge = snapshot.fetch("effective_edges").find { |item| item.fetch("id") == change.fetch("edge_id") }
      return needs_operator_action("The selected declaration is not in the analysis snapshot.") unless edge

      issue = Issue.find(edge.fetch("from_issue_id"))
      return needs_operator_action("The selected declaration has no issue-body provenance.") unless edge["declaration_source"] == "issue_body"

      client = issue.project.client
      client = client.trusted_human_mutation_client if client&.respond_to?(:trusted_human_mutation_client)
      return needs_operator_action("GitHub access is unavailable for the declaration owner.") unless client

      original_body = client.issue(issue.project.full_name, issue.github_number).body.to_s
      planned_body, diagnostic = remove_unique_reference(original_body, issue:, target: Issue.find(edge.fetch("to_issue_id")))
      return needs_operator_action("The selected declaration is #{diagnostic} in the live issue body.") unless planned_body

      live_body = client.issue(issue.project.full_name, issue.github_number).body.to_s
      if live_body != original_body
        planned_body, diagnostic = remove_unique_reference(live_body, issue:, target: Issue.find(edge.fetch("to_issue_id")))
        return needs_operator_action("The selected declaration changed and is #{diagnostic} in the live issue body.") unless planned_body
      end

      return needs_operator_action("The planned body does not remove only the selected dependency edge.") unless graph_matches?(planned_body, edge:, issue:)

      client.update_issue(issue.project.full_name, issue.github_number, body: planned_body)
      issue.update!(body: planned_body)
      comments = client.recent_issue_comments(issue.project.full_name, issue.github_number)
      Issues::ParseDependencies.call(issue:, body: planned_body, comments: comments)
      Result.new(status: :applied, message: "Removed dependency declaration from ##{issue.github_number}.")
    end

    def remove_unique_reference(body, issue:, target:)
      reference = issue.project_id == target.project_id ? "##{target.github_number}" : external_reference(target)
      lines = body.lines
      matches = declaration_matches(lines, reference)
      return [ nil, "missing" ] if matches.empty?
      return [ nil, "ambiguous" ] unless matches.one?

      index = matches.first
      line = lines[index]
      replacement = line.sub(reference, "").gsub(/[ \t]{2,}/, " ").sub(/[ \t]+\z/, "")
      lines[index] = replacement.strip == "-" ? "" : replacement
      [ lines.join, nil ]
    end

    def declaration_matches(lines, reference)
      in_dependency_section = false
      in_child_section = false
      in_fence = false
      in_list_item = false
      lines.each_index.select do |index|
        line = lines[index]
        if line.match?(Issues::ParseDependencies::FENCED_CODE_BLOCK_PATTERN)
          in_fence = !in_fence
          next false
        end
        next false if in_fence

        if (heading = line.match(Issues::ParseDependencies::MARKDOWN_HEADING_PATTERN))
          title = heading[1]
          in_dependency_section = title.match?(Issues::ParseDependencies::DEPENDENCY_HEADING_PATTERN)
          in_child_section = title.match?(Issues::ParseDependencies::CHILD_LISTING_HEADING_PATTERN)
          in_list_item = false
          next false
        end

        if line.match?(Issues::ParseDependencies::LIST_ITEM_PATTERN)
          in_list_item = in_dependency_section
        elsif line.strip.present? && !line.match?(Issues::ParseDependencies::CONTINUATION_LINE_PATTERN)
          in_list_item = false
        end
        next false if in_child_section

        dependency_line?(line, reference, in_dependency_section, in_list_item)
      end
    end

    def dependency_line?(line, reference, in_dependency_section, in_list_item)
      return false unless line.match?(/(?:^|\s)#{Regexp.escape(reference)}(?:\b|\s|,|$)/i)
      return true if in_dependency_section && in_list_item

      line.match?(/\b(?:depends?\s+on|blocked?\s+by)\b/i)
    end

    def graph_matches?(body, edge:, issue:)
      local_refs, = Issues::ParseDependencies.extract(body: body)
      target = Issue.find(edge.fetch("to_issue_id"))
      return false if local_refs.key?(target.github_number)

      snapshot.fetch("effective_edges").select { |item| item.fetch("from_issue_id") == issue.id }
        .reject { |item| item.fetch("id") == edge.fetch("id") }
        .all? do |item|
          local_refs.key?(Issue.find(item.fetch("to_issue_id")).github_number)
        end
    end

    def external_reference(issue)
      "#{issue.project.owner}/#{issue.project.repo}##{issue.github_number}"
    end

    def unauthorized = Result.new(status: :unauthorized, message: "Issue-mutation authority is required for every declaration owner.")
    def stale = Result.new(status: :stale, message: "The dependency-cycle analysis is stale; synchronize and analyze again.")
    def needs_operator_action(message) = Result.new(status: :needs_operator_action, message: message)
  end
end
