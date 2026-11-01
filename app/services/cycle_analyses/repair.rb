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
      return result("needs_operator_action", "github_comment_write_suppressed") if comment_write_suppressed?(declaration)

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
      target = Issue.find(edge.to_id)
      declaration = source_declaration(edge, issue:, target:, client:)
      return declaration if declaration[:reason]

      edited = remove_unique_declaration(declaration.fetch(:source_body), target:, source_project: issue.project)
      return { reason: removal_reason(edited) } unless edited.is_a?(String)

      declaration.merge(body: edited)
    end

    # GitHub has no conditional issue PATCH, so the body is re-read immediately
    # before writing. When a human edit lands between the two reads, the
    # removal is recomputed against their text so the edit survives the repair;
    # a changed body without a unique removable declaration aborts the write.
    # Mirrors ClarifyingQuestions::DescriptionSection#update_issue_body.
    def current_declaration(declaration)
      source = current_source(declaration)
      return { reason: "live_declaration_missing" } unless source

      body = source.fetch(:body)
      return declaration if body == declaration.fetch(:source_body)

      edited = remove_unique_declaration(body, target: declaration.fetch(:target), source_project: declaration.fetch(:project))
      return { reason: removal_reason(edited) } unless edited.is_a?(String)

      declaration.merge(source_body: body, body: edited, comment_id: source[:comment_id])
    end

    def removal_reason(outcome)
      outcome == :ambiguous ? "live_declaration_ambiguous" : "live_declaration_missing"
    end

    def issue_body(client:, project:, issue_number:)
      remote = client.issue(project.full_name, issue_number)
      field(remote, :body).to_s
    end

    def source_declaration(edge, issue:, target:, client:)
      case edge.declaration_source
      when "issue_body"
        issue_declaration(issue:, target:, client:)
      when "issue_comment"
        comment_declaration(edge.declaration_url, issue:, target:, client:)
      when nil
        unprovenanced_declaration(issue:, target:, client:)
      else
        { reason: "live_declaration_missing" }
      end
    end

    def issue_declaration(issue:, target:, client:)
      body = issue_body(client:, project: issue.project, issue_number: issue.github_number)
      declaration(issue:, target:, client:, source_type: "issue_body", source_body: body)
    end

    def comment_declaration(url, issue:, target:, client:)
      return { reason: "live_declaration_missing" } if url.blank?

      comment = issue_comments(client:, issue:).find { |candidate| field(candidate, :html_url) == url }
      return { reason: "live_declaration_missing" } unless comment && trusted_comment?(issue.project, comment)
      return { reason: "live_declaration_missing" } unless field(comment, :id)

      declaration(issue:, target:, client:, source_type: "issue_comment", source_body: field(comment, :body).to_s,
        declaration_url: url, comment_id: field(comment, :id))
    end

    def unprovenanced_declaration(issue:, target:, client:)
      body_declaration = issue_declaration(issue:, target:, client:)
      body_outcome = remove_unique_declaration(body_declaration.fetch(:source_body), target:, source_project: issue.project)
      return body_declaration if body_outcome.is_a?(String)
      return { reason: removal_reason(body_outcome) } if body_outcome == :ambiguous

      declarations = issue_comments(client:, issue:).filter_map do |comment|
        next unless trusted_comment?(issue.project, comment)
        next unless field(comment, :html_url) && field(comment, :id)

        declaration(issue:, target:, client:, source_type: "issue_comment", source_body: field(comment, :body).to_s,
          declaration_url: field(comment, :html_url), comment_id: field(comment, :id))
      end
      outcomes = declarations.to_h do |candidate|
        [ candidate, remove_unique_declaration(candidate.fetch(:source_body), target:, source_project: issue.project) ]
      end
      return { reason: "live_declaration_ambiguous" } if outcomes.value?(:ambiguous)

      matches = outcomes.select { |_candidate, outcome| outcome.is_a?(String) }.keys
      return { reason: "live_declaration_missing" } if matches.empty?
      return { reason: "live_declaration_ambiguous" } unless matches.one?

      matches.sole
    end

    def declaration(issue:, target:, client:, source_type:, source_body:, declaration_url: nil, comment_id: nil)
      { client:, project: issue.project, project_id: issue.project_id, issue_number: issue.github_number, target:,
        source_type:, source_body:, declaration_url:, comment_id: }
    end

    def current_source(declaration)
      if declaration.fetch(:source_type) == "issue_body"
        { body: issue_body(client: declaration.fetch(:client), project: declaration.fetch(:project),
          issue_number: declaration.fetch(:issue_number)) }
      else
        comment = issue_comments(client: declaration.fetch(:client), project: declaration.fetch(:project),
          issue_number: declaration.fetch(:issue_number)).find do |candidate|
          field(candidate, :html_url) == declaration.fetch(:declaration_url)
        end
        return unless comment && trusted_comment?(declaration.fetch(:project), comment)
        return unless field(comment, :id)

        { body: field(comment, :body).to_s, comment_id: field(comment, :id) }
      end
    end

    def issue_comments(client:, issue: nil, project: nil, issue_number: nil)
      project ||= issue.project
      issue_number ||= issue.github_number
      client.issue_comments(project.full_name, issue_number)
    end

    def trusted_comment?(project, comment)
      user = field(comment, :user)
      project.trusted_github_user?(field(user, :login)) if user
    end

    def remove_unique_declaration(body, target:, source_project:)
      full_local, full_cross = Issues::ParseDependencies.extract(body:)
      return :missing unless dependencies_declare_target?(full_local, full_cross, target:, source_project:)

      lines = body.lines
      carriers = lines.each_index.select do |index|
        reduced_local, reduced_cross = Issues::ParseDependencies.extract(body: lines.reject.with_index { |_line, position| position == index }.join)
        removes_target?(full_local, full_cross, reduced_local, reduced_cross, target:, source_project:) &&
          line_declares_target?(lines[index], target:, source_project:)
      end
      return :ambiguous unless carriers.one?

      lines.reject.with_index { |_line, index| index == carriers.first }.join
    end

    def removes_target?(full_local, full_cross, reduced_local, reduced_cross, target:, source_project:)
      expected_local = source_project.id == target.project_id ? full_local.except(target.github_number) : full_local
      expected_cross = full_cross.except(cross_key(target))
      reduced_local == expected_local && reduced_cross == expected_cross
    end

    def dependencies_declare_target?(local, cross, target:, source_project:)
      (source_project.id == target.project_id && local.key?(target.github_number)) || cross.key?(cross_key(target))
    end

    def line_declares_target?(line, target:, source_project:)
      local, cross = Issues::ParseDependencies.extract(body: "## Dependencies\n#{line}")
      dependencies_declare_target?(local, cross, target:, source_project:)
    end

    def cross_key(target)
      [ target.project.owner.downcase, target.project.repo.downcase, target.github_number ]
    end

    def canonical_edges(edges)
      edges.map { |edge| [ edge.fetch("from_issue_id"), edge.fetch("to_issue_id") ] }.sort
    end

    def comment_write_suppressed?(declaration)
      declaration.fetch(:source_type) == "issue_comment" &&
        declaration.fetch(:client).is_a?(GithubClient::CommentSuppressing)
    end

    def write(declaration)
      if declaration.fetch(:source_type) == "issue_body"
        declaration.fetch(:client).update_issue(declaration.fetch(:project).full_name,
          declaration.fetch(:issue_number), body: declaration.fetch(:body))
      else
        declaration.fetch(:client).update_comment(declaration.fetch(:project).full_name,
          declaration.fetch(:comment_id), declaration.fetch(:body))
      end
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
