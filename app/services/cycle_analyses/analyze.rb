# frozen_string_literal: true

module CycleAnalyses
  class Analyze
    def self.call(...) = new(...).call

    def initialize(agent_run:, llm: Llm::Request)
      @agent_run = agent_run
      @llm = llm
    end

    # @spec AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-019
    def call
      response = llm.call(prompt: prompt, agent_run:, timeout: 5.minutes)
      { "recommendation" => response_text(response), "coverage" => coverage, "graph_revision" => snapshot.fetch("graph_revision") }
    end

    private

    attr_reader :agent_run, :llm

    def snapshot = agent_run.external_metadata.fetch(METADATA_KEY)

    def cycle
      @cycle ||= Issues::DependencyCycles.call(account: agent_run.project.account).find { |candidate| candidate.occurrence == snapshot.fetch("occurrence") }
    end

    def prompt
      raise "Cycle occurrence is no longer present in the effective graph" unless cycle

      <<~PROMPT
        You are performing a read-only dependency-cycle analysis. Do not propose automatic edits.
        Review the complete strongly connected group and every effective edge below, not only a witness path.
        For each candidate declaration change, state exact evidence, tradeoffs, missing/conflicting intent,
        the resulting graph, and whether it is acyclic. Removing one edge is not presumed sufficient.
        #{JSON.pretty_generate(graph_payload)}
      PROMPT
    end

    def graph_payload
      { occurrence: cycle.occurrence, graph_revision: cycle.graph_revision,
        issues: cycle.issues.map { |issue| issue_payload(issue) },
        effective_edges: cycle.effective_edges.map { |edge| edge_payload(edge) }, coverage: coverage }
    end

    def issue_payload(issue)
      { id: issue.id, project: issue.project.full_name, number: issue.github_number, title: issue.title,
        labels: issue.labels, parent: parent_payload(issue), url: issue.github_url, body: capped(issue.body),
        trusted_comments: trusted_comments(issue) }
    end

    def parent_payload(issue)
      parent = issue.parent_issue
      return unless parent

      { project: parent.project.full_name, number: parent.github_number, title: parent.title, url: parent.github_url }
    end

    def edge_payload(edge)
      { id: edge.id, from_issue_id: edge.from_id, to_issue_id: edge.to_id,
        declaration_source: edge.declaration_source, declaration_url: edge.declaration_url }
    end

    def trusted_comments(issue)
      Prompts::BuildForIssue.fetch_trusted_comments(github_client: issue.project.client, repo: issue.project.full_name,
        number: issue.github_number, project: issue.project).map do |comment|
          { author: comment.user.login, body: capped(comment.body), url: comment.html_url }
        end
    rescue GithubClient::Error
      []
    end

    def coverage
      { "unavailable_provenance_edge_ids" => cycle.effective_edges.filter_map { |edge| edge.id if edge.declaration_url.blank? },
        "unavailable_content_issue_ids" => cycle.issues.filter_map { |issue| issue.id if issue.body.blank? } }
    end

    def capped(content)
      content.to_s[0, Prompts::BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH]
    end

    def response_text(response)
      return response.content if response.respond_to?(:content)
      return response.text if response.respond_to?(:text)

      response.to_s
    end
  end
end
