# frozen_string_literal: true

module CycleAnalyses
  # Applies a cycle analysis recommendation to repair dependency declarations,
  # including authority and graph-staleness safeguards. Handles mutations to
  # declarations from issue bodies and admitted comments.
  #
  # @spec AUTO-PICK-QUEUE-019
  class ApplyRepair
    Result = Data.define(:status, :mutations) do
      def applied? = status == "applied"
    end

    def self.call(...) = new(...).call

    def initialize(cycle:, actor:, recommendation:, snapshot: nil)
      @cycle = cycle
      @actor = actor
      @recommendation = recommendation
      @snapshot = snapshot
      @mutations = {}
    end

    # @spec AUTO-PICK-QUEUE-019
    def call
      verify_authority!
      verify_graph_freshness!
      apply_mutations!
      Result.new(status: "applied", mutations: @mutations)
    end

    private

    attr_reader :cycle, :actor, :recommendation, :snapshot

    def verify_authority!
      unless actor.account_memberships.exists?(account: cycle.project.account)
        raise CycleAnalyses::InsufficientAuthority, "Actor is not a member of the account owning the cycle"
      end
    end

    def verify_graph_freshness!
      current_cycle = Issues::DependencyCycles.call(account: cycle.project.account)
        .find { |c| c.fingerprint == cycle.fingerprint }

      if current_cycle.nil? || current_cycle.occurrence != cycle.occurrence
        raise CycleAnalyses::StaleCycleGraph, "The dependency cycle graph has changed since the recommendation was generated"
      end
    end

    def apply_mutations!
      projects_cache = {}
      recommendation["candidates"].first.fetch("declaration_changes").each do |change|
        # Get edge data from the snapshot
        snapshot_data = fetch_snapshot_data
        edge_data = snapshot_data&.fetch("effective_edges", [])&.find { |e| e["id"] == change["edge_id"] }
        next unless edge_data && edge_data["declaration_url"].present?

        from_issue_id = edge_data["from_issue_id"]
        project = projects_cache[from_issue_id.to_s] ||= fetch_issue_project(from_issue_id)
        next unless project

        client = project.client

        if edge_data["declaration_source"] == "body"
          apply_body_mutation(client, project, edge_data, change)
        elsif edge_data["declaration_source"] == "comment"
          apply_comment_mutation(client, project, edge_data, change)
        end
      end
    end

    def apply_body_mutation(client, project, edge_data, change)
      issue = cycle.issues.find { |i| i.id == edge_data["from_issue_id"] }
      return unless issue

      updated_body = mutate_text(issue.body, edge_data, change)
      return if updated_body == issue.body

      client.update_issue(project.full_name, issue.github_number, body: updated_body)
      @mutations[edge_data["id"].to_s] = { "action" => change["action"], "source" => "body" }
    end

    def apply_comment_mutation(client, project, edge_data, change)
      # Extract comment ID from the URL (e.g., .../issues/123#issuecomment-456)
      comment_id = extract_comment_id(edge_data["declaration_url"])
      return unless comment_id

      comment = client.issue_comment(project.full_name, comment_id)
      updated_body = mutate_text(comment.body, edge_data, change)
      return if updated_body == comment.body

      client.update_comment(project.full_name, comment_id, updated_body)
      @mutations[edge_data["id"].to_s] = { "action" => change["action"], "source" => "comment", "comment_id" => comment_id }
    end

    def mutate_text(text, edge_data, change)
      # Build a pattern to find the dependency reference in the text
      issue = cycle.issues.find { |i| i.id == edge_data["to_issue_id"] }
      return text unless issue

      ref = "##{issue.github_number}"
      depends_pattern = %r{depends?\s+on[:\s]+#{Regexp.escape(ref)}|blocked?\s+by[:\s]+#{Regexp.escape(ref)}}i

      if change["action"] == "remove"
        # Remove the dependency declaration or the line containing it
        remove_dependency(text, ref, depends_pattern)
      elsif change["action"] == "correct"
        # Correct the endpoint
        correct_dependency(text, edge_data, change, ref, depends_pattern)
      else
        text
      end
    end

    def remove_dependency(text, ref, pattern)
      # Remove the dependency reference, cleaning up any orphaned bullets or formatting
      lines = text.split("\n")
      result_lines = lines.filter_map do |line|
        if line.match?(pattern)
          # If it's a list item, remove the whole line
          if line.match?(/^\s*[-*+]\s+/)
            next nil
          end
          # Otherwise, just remove the pattern from the line
          line.gsub(pattern, "").strip.presence
        else
          line
        end
      end
      result_lines.join("\n").strip
    end

    def correct_dependency(text, edge_data, change, ref, pattern)
      old_issue = cycle.issues.find { |i| i.id == edge_data["to_issue_id"] }
      new_issue = cycle.issues.find { |i| i.id == change["replacement"]["to_issue_id"] }
      return text unless old_issue && new_issue

      new_ref = "##{new_issue.github_number}"
      text.gsub(pattern) { |match| match.gsub(Regexp.escape(ref), new_ref) }
    end

    def extract_comment_id(url)
      # URL format: https://github.com/owner/repo/issues/123#issuecomment-456
      match = url.match(/#issuecomment-(\d+)/)
      match&.[](1)&.to_i
    end

    def fetch_snapshot_data
      @snapshot
    end

    def fetch_issue_project(issue_id)
      issue = cycle.issues.find { |i| i.id == issue_id }
      issue&.project
    end
  end
end
