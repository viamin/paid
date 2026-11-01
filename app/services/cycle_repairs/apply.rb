# frozen_string_literal: true

module CycleRepairs
  # Applies the bounded first-path repair for one dependency-cycle occurrence:
  # remove the first witness-path edge's declaration from the live declaring
  # issue body. The workflow is deliberately bounded — it never chooses among
  # candidate edges, never edits comments, and removes exactly one body line —
  # and it refuses to act unless the live body still carries an unambiguous
  # declaration and removing the edge breaks the strongly connected group.
  # @spec AUTO-PICK-QUEUE-021
  class Apply
    Result = Data.define(:status, :message, :occurrence, :edge_id, :from_issue, :to_issue, :removed_declaration) do
      def applied? = status == :applied

      def payload
        {
          status: status.to_s,
          message:,
          occurrence:,
          edge_id:,
          from_issue: issue_payload(from_issue),
          to_issue: issue_payload(to_issue),
          removed_declaration:
        }.compact
      end

      private

      def issue_payload(issue)
        return unless issue

        { "project" => issue.project.full_name, "number" => issue.github_number, "url" => issue.github_url }
      end
    end

    Context = Data.define(:edge, :from_issue, :to_issue)

    def self.call(...) = new(...).call

    def initialize(cycle:, actor:)
      @cycle = cycle
      @actor = actor
    end

    def call
      context = context_for_first_edge
      return refused(:edge_not_repairable, context,
        "The first path edge is declared in a comment; remove the declaring comment on GitHub instead.") if comment_declared?(context.edge)

      match = DeclarationMatch.call(body: fetch_live_body(context.from_issue),
        from_issue: context.from_issue, to_issue: context.to_issue)
      return refused(:declaration_missing, context, match.message) if match.status == :missing
      return refused(:declaration_ambiguous, context, match.message) if match.status == :ambiguous
      return refused(:cycle_unresolved, context,
        "Removing the first path edge leaves a cycle among the occurrence's members; review every declaration on GitHub.") unless PostRemovalGraph.acyclic_after_removal?(cycle:, edge: context.edge)

      apply_repair(context, match)
    end

    private

    attr_reader :cycle, :actor

    def context_for_first_edge
      Context.new(edge: cycle.path_edges.first, from_issue: cycle.path.first, to_issue: cycle.path.second)
    end

    def comment_declared?(edge)
      edge.declaration_source == "issue_comment"
    end

    def fetch_live_body(issue)
      read_client(issue.project).issue(issue.project.full_name, issue.github_number).body.to_s
    end

    def read_client(project)
      project.client || raise(ArgumentError, "Project has no GitHub credential configured")
    end

    def apply_repair(context, match)
      project = context.from_issue.project
      updated = mutation_client(project).update_issue(project.full_name,
        context.from_issue.github_number, body: match.edited_body)
      issue = Issues::UpsertFromGithub.call(project:, github_issue: updated)
      Issues::ParseDependencies.call(issue:)
      Audit::RecordEvent.call(action: "issue.updated", actor:, subject: project, metadata: audit_metadata(context, match))
      log_repair_applied(context)
      Result.new(status: :applied, message: "Removed the declaration from the declaring issue body.",
        occurrence: cycle.occurrence, edge_id: context.edge.id, from_issue: context.from_issue,
        to_issue: context.to_issue, removed_declaration: match.declaration)
    end

    def mutation_client(project)
      client = read_client(project)
      client = client.trusted_human_mutation_client if client.respond_to?(:trusted_human_mutation_client)
      unless project.trusted_github_user?(client.authenticated_login)
        raise ArgumentError, "Dependency-cycle repairs require a trusted human GitHub credential"
      end

      client
    end

    def refused(status, context, message)
      Result.new(status:, message:, occurrence: cycle.occurrence, edge_id: context.edge.id,
        from_issue: context.from_issue, to_issue: context.to_issue, removed_declaration: nil)
    end

    def audit_metadata(context, match)
      {
        operation: "dependency_cycle_repair",
        occurrence: cycle.occurrence,
        edge_id: context.edge.id,
        issue_number: context.from_issue.github_number,
        depends_on_issue_number: context.to_issue.github_number,
        removed_declaration: match.declaration
      }
    end

    def log_repair_applied(context)
      Rails.logger.info(
        message: "dependency_cycle.repair_applied",
        account_id: account.id,
        occurrence: cycle.occurrence,
        edge_id: context.edge.id,
        issue_id: context.from_issue.id,
        depends_on_issue_id: context.to_issue.id
      )
    end

    def account
      cycle.account
    end
  end
end
