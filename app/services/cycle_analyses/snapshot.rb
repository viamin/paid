# frozen_string_literal: true

module CycleAnalyses
  class Snapshot
    def self.call(...) = new(...).call

    def initialize(cycle:)
      @cycle = cycle
    end

    # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-017
    def call
      {
        "fingerprint" => cycle.fingerprint,
        "occurrence" => cycle.occurrence,
        "graph_revision" => cycle.graph_revision,
        "project_ids" => cycle.project_ids,
        "issues" => cycle.issues.map { |issue| issue_payload(issue) },
        "effective_edges" => cycle.effective_edges.map { |edge| edge_payload(edge) }
      }
    end

    private

    attr_reader :cycle

    def issue_payload(issue)
      {
        "id" => issue.id,
        "project_id" => issue.project_id,
        "project" => issue.project.full_name,
        "number" => issue.github_number,
        "title" => issue.title,
        "labels" => issue.labels,
        "parent" => parent_payload(issue.parent_issue),
        "url" => issue.github_url,
        "body" => issue.trusted? ? issue.body : nil
      }
    end

    def parent_payload(parent)
      return unless parent

      { "project" => parent.project.full_name, "number" => parent.github_number,
        "title" => parent.title, "url" => parent.github_url }
    end

    def edge_payload(edge)
      { "id" => edge.id, "from_issue_id" => edge.from_id, "to_issue_id" => edge.to_id,
        "declaration_source" => edge.declaration_source, "declaration_url" => edge.declaration_url }
    end
  end
end
