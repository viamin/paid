# frozen_string_literal: true

module DependencyCycles
  # Builds a bounded, auditable prompt input. Comments cross a trust boundary
  # before they reach the agent; unavailable remote coverage is evidence, not
  # an empty comment list.
  # @spec AUTO-PICK-QUEUE-017
  class AnalysisContext
    def self.call(...) = new(...).call

    def initialize(cycle:, github_client_resolver: ->(project) { project.client if project.github_credential_present? })
      @cycle = cycle
      @github_client_resolver = github_client_resolver
    end

    def call
      {
        occurrence: cycle.occurrence,
        graph_revision: cycle.graph_revision,
        members: cycle.issues.map { |issue| issue_payload(issue) },
        effective_edges: effective_edges,
        instructions: instructions
      }
    end

    private

    attr_reader :cycle, :github_client_resolver

    def issue_payload(issue)
      {
        project: issue.project.full_name, number: issue.github_number, title: issue.title,
        labels: issue.labels, url: issue.github_url, body: issue.body,
        parent: parent_payload(issue), trusted_comments: trusted_comments(issue)
      }
    end

    def parent_payload(issue)
      parent = issue.parent_issue
      return unless parent

      { project: parent.project.full_name, number: parent.github_number, title: parent.title, url: parent.github_url }
    end

    def trusted_comments(issue)
      client = github_client_resolver.call(issue.project)
      return { coverage: "unavailable", reason: "GitHub credential unavailable", comments: [] } unless client

      comments = Prompts::BuildForIssue.fetch_trusted_comments(github_client: client, repo: issue.project.full_name,
        number: issue.github_number, project: issue.project)
      { coverage: "available", comments: comments.map { |comment| { author: comment.user.login, body: comment.body, url: comment.html_url } } }
    rescue GithubClient::Error => error
      { coverage: "unavailable", reason: error.message, comments: [] }
    end

    def effective_edges
      issue_by_id = cycle.issues.index_by(&:id)
      cycle.component_edges.map do |edge|
        from, to = issue_by_id.fetch(edge.from_id), issue_by_id.fetch(edge.to_id)
        { from: issue_ref(from), to: issue_ref(to), declaration_source: edge.declaration_source, declaration_url: edge.declaration_url,
          provenance_coverage: edge.declaration_url.present? ? "available" : "unavailable" }
      end
    end

    def issue_ref(issue) = { project: issue.project.full_name, number: issue.github_number, url: issue.github_url }

    def instructions
      "Read-only analysis only. Evaluate every effective edge in this strongly connected component, not just the witness path. Propose candidate declaration changes with evidence and tradeoffs, identify missing or conflicting intent, and simulate each proposed resulting graph. State explicitly whether each simulation is acyclic; do not claim one removed edge necessarily resolves the group. Do not edit issues, comments, labels, dependency records, or GitHub declarations."
    end
  end
end
