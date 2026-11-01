# frozen_string_literal: true

module CycleAnalyses
  # Deterministic gates around the semantic recommendation. This deliberately
  # performs no local dependency synchronization: GitHub's next normal sync is
  # the authority that confirms whether the repair cleared the effective graph.
  class Repair
    Result = Data.define(:status, :reason, :changed_edge_ids, :details) do
      def to_h = { "status" => status, "reason" => reason, "changed_edge_ids" => changed_edge_ids, "details" => details }
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, recommendation:, client_resolver: ->(project) { project.client })
      @agent_run = agent_run
      @recommendation = recommendation
      @client_resolver = client_resolver
    end

    # @spec AUTO-PICK-QUEUE-019
    def call
      return result("needs_operator_action", "not_obvious") unless obvious?
      return result("needs_operator_action", "unauthorized") unless authorized?

      live_cycle = current_cycle
      return result("needs_operator_action", "graph_changed") unless live_cycle&.occurrence == snapshot.fetch("occurrence")
      return result("needs_operator_action", "resulting_graph_changed") unless resulting_graph_matches?

      edge = live_cycle.effective_edges.find { |candidate| candidate.id == change.fetch("edge_id") }
      return result("needs_operator_action", "edge_changed") unless edge

      declaration = live_declaration(edge)
      return result("needs_operator_action", declaration.fetch(:reason)) unless declaration[:body]

      write(declaration, edge)
      result("pending_sync", "awaiting_github_synchronization", [ edge.id ], declaration.slice(:project_id, :issue_number))
    rescue GithubClient::AuthenticationError
      result("needs_operator_action", "github_authorization_failed")
    rescue GithubClient::Error => error
      result("needs_operator_action", "github_write_failed", [], { "error" => error.message })
    end

    private

    attr_reader :agent_run, :client_resolver, :recommendation

    def snapshot = agent_run.external_metadata.fetch(METADATA_KEY)
    def candidate = recommendation.fetch("candidates").sole
    def change = candidate.fetch("declaration_changes").sole

    def obvious?
      recommendation.fetch("candidates", []).one? && candidate.fetch("acyclic") &&
        candidate.fetch("evidence", []).any? && candidate.fetch("missing_or_conflicting_intent", []).empty? &&
        candidate.fetch("declaration_changes", []).one? && change.fetch("action") == "remove"
    end

    def authorized?
      projects.all? { |project| ProjectPolicy.new(agent_run.initiating_user, project).run_agent? && ProjectPolicy.new(agent_run.initiating_user, project).manage_issues? }
    end

    def projects
      @projects ||= Project.where(id: snapshot.fetch("project_ids")).index_by(&:id).values
    end

    def current_cycle
      Issues::DependencyCycles.call(account: agent_run.project.account)
        .find { |cycle| cycle.occurrence == snapshot.fetch("occurrence") }
    end

    def resulting_graph_matches?
      expected = candidate.fetch("resulting_graph")
      AcyclicGraph.call(issue_ids: expected.fetch("issue_ids"), edges: expected.fetch("edges"))
    end

    def live_declaration(edge)
      issue = Issue.find(edge.from_id)
      return { reason: "untrusted_source" } unless issue.trusted?

      client = client_resolver.call(issue.project)
      remote = client.issue(issue.project.full_name, issue.github_number)
      body = field(remote, :body).to_s
      edited = remove_unique_declaration(body, target_number: Issue.find(edge.to_id).github_number)
      return { reason: edited ? "live_declaration_missing" : "live_declaration_ambiguous" } unless edited

      { client:, body: edited, project_id: issue.project_id, issue_number: issue.github_number, project: issue.project }
    end

    def remove_unique_declaration(body, target_number:)
      matches = body.lines.each_index.select do |index|
        local, = Issues::ParseDependencies.extract(body: body.lines[index])
        local.keys == [ target_number ]
      end
      return if matches.size != 1

      body.lines.reject.with_index { |_line, index| index == matches.first }.join
    end

    def write(declaration, _edge)
      declaration.fetch(:client).update_issue(declaration.fetch(:project).full_name,
        declaration.fetch(:issue_number), body: declaration.fetch(:body))
    end

    def field(source, name)
      return source.public_send(name) if source.respond_to?(name)
      return source[name] if source.respond_to?(:key?) && source.key?(name)

      source[name.to_s]
    end

    def result(status, reason, changed_edge_ids = [], details = {})
      Result.new(status, reason, changed_edge_ids, details).to_h
    end
  end
end
