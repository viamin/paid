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
      validate_changes!(require_nonempty_array!(candidate["declaration_changes"], "#{path}.declaration_changes"), path)
      require_text_array!(candidate["evidence"], "#{path}.evidence", allow_empty: false)
      require_text_array!(candidate["tradeoffs"], "#{path}.tradeoffs", allow_empty: false)
      require_text_array!(candidate["missing_or_conflicting_intent"], "#{path}.missing_or_conflicting_intent")
      validate_graph!(candidate["resulting_graph"], path)
      invalid!("#{path}.acyclic must be boolean") unless [ true, false ].include?(candidate["acyclic"])
      validate_acyclicity!(candidate, path)
    end

    def validate_changes!(changes, path)
      changes.each_with_index do |change, index|
        change_path = "#{path}.declaration_changes[#{index}]"
        require_object!(change, change_path)
        invalid!("#{change_path}.edge_id must be an integer") unless change["edge_id"].is_a?(Integer)
        unless snapshot_edge_ids.include?(change["edge_id"])
          invalid!("#{change_path}.edge_id is not in the snapshotted cycle")
        end
        require_text!(change["action"], "#{change_path}.action")
      end
    end

    def validate_graph!(graph, path)
      require_object!(graph, "#{path}.resulting_graph")
      invalid!("#{path}.resulting_graph.issue_ids must be an array of integers") unless integer_array?(graph["issue_ids"])
      unless graph["issue_ids"].sort == snapshot_issue_ids.sort
        invalid!("#{path}.resulting_graph.issue_ids must match the snapshotted cycle")
      end
      invalid!("#{path}.resulting_graph.edges must be an array") unless graph["edges"].is_a?(Array)
      graph["edges"].each_with_index do |edge, index|
        validate_edge!(edge, "#{path}.resulting_graph.edges[#{index}]", graph["issue_ids"])
      end
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
