# frozen_string_literal: true

module CycleAnalyses
  class Response
    def self.parse(output, snapshot:)
      response = new(JSON.parse(output.to_s), snapshot:)
      response.validate!
      response.payload
    rescue JSON::ParserError
      raise InvalidResponse, "Cycle analysis must return valid JSON."
    end

    attr_reader :payload

    def initialize(payload, snapshot:)
      @payload = payload
      @snapshot = snapshot
    end

    # @spec AUTO-PICK-QUEUE-018
    def validate!
      require_object!(payload, "recommendation")
      require_text!(payload["summary"], "summary")
      candidates = require_nonempty_array!(payload["candidates"], "candidates")
      candidates.each_with_index { |candidate, index| validate_candidate!(candidate, index) }
    end

    private

    attr_reader :snapshot

    def validate_candidate!(candidate, index)
      path = "candidates[#{index}]"
      require_object!(candidate, path)
      changes = require_nonempty_array!(candidate["declaration_changes"], "#{path}.declaration_changes")
      validate_changes!(changes, path)
      require_text_array!(candidate["evidence"], "#{path}.evidence", allow_empty: false)
      require_text_array!(candidate["tradeoffs"], "#{path}.tradeoffs", allow_empty: false)
      require_text_array!(candidate["missing_or_conflicting_intent"], "#{path}.missing_or_conflicting_intent")
      validate_graph!(candidate["resulting_graph"], changes, path)
      invalid!("#{path}.acyclic must be boolean") unless [ true, false ].include?(candidate["acyclic"])
      validate_acyclicity!(candidate, path)
    end

    def validate_changes!(changes, path)
      validate_unique_edge_ids!(changes, path)
      changes.each_with_index do |change, index|
        change_path = "#{path}.declaration_changes[#{index}]"
        require_object!(change, change_path)
        invalid!("#{change_path}.edge_id must be an integer") unless change["edge_id"].is_a?(Integer)
        unless snapshot_edge_ids.include?(change["edge_id"])
          invalid!("#{change_path}.edge_id is not in the snapshotted cycle")
        end
        validate_action!(change, change_path)
      end
    end

    def validate_unique_edge_ids!(changes, path)
      edge_ids = changes.filter_map { |change| change["edge_id"] if change.is_a?(Hash) }
      invalid!("#{path}.declaration_changes edge_id must be unique") unless edge_ids.uniq.size == edge_ids.size
    end

    def validate_action!(change, path)
      case change["action"]
      when "remove"
        invalid!("#{path}.replacement is only valid for corrections") if change.key?("replacement")
      when "correct"
        require_object!(change["replacement"], "#{path}.replacement")
        validate_edge!(change["replacement"], "#{path}.replacement", snapshot_issue_ids)
      else
        invalid!("#{path}.action must be remove or correct")
      end
    end

    def validate_graph!(graph, changes, path)
      require_object!(graph, "#{path}.resulting_graph")
      invalid!("#{path}.resulting_graph.issue_ids must be an array of integers") unless integer_array?(graph["issue_ids"])
      unless graph["issue_ids"].sort == snapshot_issue_ids.sort
        invalid!("#{path}.resulting_graph.issue_ids must match the snapshotted cycle")
      end
      invalid!("#{path}.resulting_graph.edges must be an array") unless graph["edges"].is_a?(Array)
      graph["edges"].each_with_index do |edge, index|
        validate_edge!(edge, "#{path}.resulting_graph.edges[#{index}]", graph["issue_ids"])
      end
      validate_expected_edges!(graph["edges"], changes, path)
    end

    def validate_edge!(edge, path, issue_ids)
      require_object!(edge, path)
      %w[from_issue_id to_issue_id].each do |key|
        invalid!("#{path}.#{key} must be an integer") unless edge[key].is_a?(Integer)
        invalid!("#{path}.#{key} is not in the resulting graph") unless issue_ids.include?(edge[key])
      end
    end

    def validate_acyclicity!(candidate, path)
      graph = candidate.fetch("resulting_graph")
      actual = AcyclicGraph.call(issue_ids: graph.fetch("issue_ids"), edges: graph.fetch("edges"))
      invalid!("#{path}.acyclic does not match the resulting graph") unless candidate["acyclic"] == actual
    end

    def validate_expected_edges!(edges, changes, path)
      changes_by_id = changes.index_by { |change| change.fetch("edge_id") }
      expected = snapshot.fetch("effective_edges").filter_map do |edge|
        apply_change(edge, changes_by_id[edge.fetch("id")])
      end
      return if canonical_edges(edges) == canonical_edges(expected)

      invalid!("#{path}.resulting_graph.edges must match the snapshotted cycle after applying declaration_changes")
    end

    def apply_change(edge, change)
      return edge.slice("from_issue_id", "to_issue_id") unless change
      return if change.fetch("action") == "remove"

      change.fetch("replacement")
    end

    def canonical_edges(edges)
      edges.map { |edge| [ edge.fetch("from_issue_id"), edge.fetch("to_issue_id") ] }.sort
    end

    def snapshot_issue_ids = snapshot.fetch("issues").pluck("id")
    def snapshot_edge_ids = snapshot.fetch("effective_edges").pluck("id")

    def integer_array?(value)
      value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) }
    end

    def require_object!(value, path)
      invalid!("#{path} must be an object") unless value.is_a?(Hash)
    end

    def require_nonempty_array!(value, path)
      invalid!("#{path} must be a non-empty array") unless value.is_a?(Array) && value.any?
      value
    end

    def require_text_array!(value, path, allow_empty: true)
      valid = value.is_a?(Array) && (allow_empty || value.any?) && value.all? { |item| item.is_a?(String) && item.present? }
      invalid!("#{path} must be an array of non-empty strings") unless valid
    end

    def require_text!(value, path)
      invalid!("#{path} must be a non-empty string") unless value.is_a?(String) && value.present?
    end

    def invalid!(message)
      raise InvalidResponse, "Invalid cycle analysis response: #{message}"
    end
  end
end
