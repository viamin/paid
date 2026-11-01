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
      return result("needs_operator_action", "resulting_graph_changed") unless resulting_graph_matches?(live_cycle)

      edge = live_cycle.effective_edges.find { |candidate| candidate.id == change.fetch("edge_id") }
      return result("needs_operator_action", "edge_changed") unless edge

      declaration = live_declaration(edge)
      return result("needs_operator_action", declaration.fetch(:reason)) unless declaration[:body]

      declaration = current_declaration(declaration)
      return result("needs_operator_action", declaration.fetch(:reason)) unless declaration[:body]

      write(declaration)
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

    def resulting_graph_matches?(live_cycle)
      expected = candidate.fetch("resulting_graph")
      expected_edges = expected.fetch("edges")
      live_edges = live_cycle.effective_edges.reject { |edge| edge.id == change.fetch("edge_id") }
        .map { |edge| { "from_issue_id" => edge.from_id, "to_issue_id" => edge.to_id } }
      AcyclicGraph.call(issue_ids: expected.fetch("issue_ids"), edges: expected_edges) &&
        canonical_edges(expected_edges) == canonical_edges(live_edges)
    end

    def live_declaration(edge)
      issue = Issue.find(edge.from_id)
      return { reason: "untrusted_source" } unless issue.trusted?

      client = client_resolver.call(issue.project)
      body = issue_body(client:, project: issue.project, issue_number: issue.github_number)
      target_number = Issue.find(edge.to_id).github_number
      edited = remove_unique_declaration(body, target_number:)
      return { reason: removal_reason(edited) } unless edited.is_a?(String)

      { client:, project: issue.project, project_id: issue.project_id, issue_number: issue.github_number,
        target_number:, source_body: body, body: edited }
    end

    # GitHub has no conditional issue PATCH, so the body is re-read immediately
    # before writing. When a human edit lands between the two reads, the
    # removal is recomputed against their text so the edit survives the repair;
    # a changed body without a unique removable declaration aborts the write.
    # Mirrors ClarifyingQuestions::DescriptionSection#update_issue_body.
    def current_declaration(declaration)
      body = issue_body(client: declaration.fetch(:client), project: declaration.fetch(:project),
        issue_number: declaration.fetch(:issue_number))
      return declaration if body == declaration.fetch(:source_body)

      edited = remove_unique_declaration(body, target_number: declaration.fetch(:target_number))
      return { reason: removal_reason(edited) } unless edited.is_a?(String)

      declaration.merge(source_body: body, body: edited)
    end

    def removal_reason(outcome)
      outcome == :ambiguous ? "live_declaration_ambiguous" : "live_declaration_missing"
    end

    def issue_body(client:, project:, issue_number:)
      remote = client.issue(project.full_name, issue_number)
      field(remote, :body).to_s
    end

    def remove_unique_declaration(body, target_number:)
      full_local, = Issues::ParseDependencies.extract(body:)
      return :missing unless full_local.key?(target_number)

      lines = body.lines
      carriers = lines.each_index.select do |index|
        reduced_local, = Issues::ParseDependencies.extract(body: lines.reject.with_index { |_line, position| position == index }.join)
        reduced_local == full_local.except(target_number) && declares_target?(lines[index], target_number)
      end
      return :ambiguous unless carriers.one?

      lines.reject.with_index { |_line, index| index == carriers.first }.join
    end

    def declares_target?(line, target_number)
      local, = Issues::ParseDependencies.extract(body: "## Dependencies\n#{line}")
      local.key?(target_number)
    end

    def canonical_edges(edges)
      edges.map { |edge| [ edge.fetch("from_issue_id"), edge.fetch("to_issue_id") ] }.sort
    end

    def write(declaration)
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
