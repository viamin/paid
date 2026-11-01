# frozen_string_literal: true

module CycleAnalyses
  class Analyze
    def self.call(...) = new(...).call

    def initialize(agent_run:, llm: Llm::Request)
      @agent_run = agent_run
      @llm = llm
      @unavailable_comment_issue_ids = Set.new
    end

    # @spec AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-019
    def call
      response = llm.call(prompt: prompt, agent_run:, timeout: 5.minutes)
      validate_response!(response)
      { "recommendation" => Response.parse(response.output, snapshot:), "coverage" => coverage,
        "graph_revision" => snapshot.fetch("graph_revision") }
    end

    private

    attr_reader :agent_run, :llm, :unavailable_comment_issue_ids

    def snapshot = agent_run.external_metadata.fetch(METADATA_KEY)
    def issues = snapshot.fetch("issues")
    def effective_edges = snapshot.fetch("effective_edges")

    def prompt
      <<~PROMPT
        You are assessing a bounded dependency-cycle repair. Paid may edit only
        one declaration after deterministic authorization and live-source checks.
        Review the complete strongly connected group and every effective edge below, not only a witness path.
        Return one candidate only when it is the sole supported change set. State exact evidence, tradeoffs, missing/conflicting intent,
        the resulting graph, and whether it is acyclic. Removing one edge is not presumed sufficient.
        Return exactly one JSON object with this structure and no Markdown fencing:
        {
          "summary": "...",
          "candidates": [{
            "declaration_changes": [{
              "edge_id": 123,
              "action": "correct",
              "replacement": { "from_issue_id": 1, "to_issue_id": 2 }
            }],
            "evidence": ["..."],
            "tradeoffs": ["..."],
            "missing_or_conflicting_intent": ["..."],
            "resulting_graph": {
              "issue_ids": [1, 2],
              "edges": [{ "from_issue_id": 1, "to_issue_id": 2 }]
            },
            "acyclic": true
          }]
        }
        Use action "remove" without replacement, or action "correct" with replacement endpoints.
        The resulting graph edges must be the complete snapshotted edge set after applying exactly those changes.
        #{JSON.pretty_generate(graph_payload)}
      PROMPT
    end

    def graph_payload
      { occurrence: snapshot.fetch("occurrence"), graph_revision: snapshot.fetch("graph_revision"),
        issues: issues.map { |issue| issue_payload(issue) }, effective_edges:, coverage: coverage }
    end

    def issue_payload(issue)
      issue.merge("body" => capped(issue["body"]), "trusted_comments" => trusted_comments(issue))
    end

    def trusted_comments(issue)
      project = projects.fetch(issue.fetch("project_id"))
      comments = project.client.issue_comments(project.full_name, issue.fetch("number"))
      Prompts::BuildForIssue.fetch_trusted_comments(github_client: project.client, repo: project.full_name,
        number: issue.fetch("number"), project:, comments:).map do |comment|
          { author: comment.user.login, body: capped(comment.body), url: comment.html_url }
        end
    rescue GithubClient::Error
      unavailable_comment_issue_ids << issue.fetch("id")
      []
    end

    def projects
      @projects ||= Project.where(id: issues.pluck("project_id")).index_by(&:id)
    end

    def coverage
      unavailable_content = issues.filter_map { |issue| issue.fetch("id") if issue["body"].blank? }
      { "unavailable_provenance_edge_ids" => effective_edges.filter_map { |edge| edge.fetch("id") if edge["declaration_url"].blank? },
        "unavailable_content_issue_ids" => (unavailable_content | unavailable_comment_issue_ids.to_a) }
    end

    def capped(content)
      content.to_s[0, Prompts::BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH]
    end

    def validate_response!(response)
      return if response.success?

      detail = response.error.presence || "runner returned exit code #{response.exit_code}"
      raise AgentHarness::CommandExecutionError, "Cycle analysis failed: #{detail}"
    end
  end
end
