# frozen_string_literal: true

module OperationalSupervisor
  # Calls the owned LLM route with a persisted, sanitized snapshot. This service
  # never persists a finding: callers must send a validated finding through the
  # separate policy, precondition, and idempotency boundary.
  class Analyze
    TIMEOUT = 60.seconds
    PROMPT_IDENTIFIER = "operational-supervisor-analysis-v1"
    POLICY_IDENTIFIER = "operational-supervisor-shadow-v1"
    RECOMMENDATION_CATALOG = %w[
      inspect_conversion_funnel
      inspect_cost_allocation
      inspect_guardrail_configuration
      inspect_queue_capacity
      inspect_rework_pattern
      inspect_stage_flow
    ].freeze

    Finding = Data.define(:category, :severity, :affected_project_ids, :target_ids, :evidence, :recommendation)
    Result = Data.define(:findings, :model_identifier, :prompt_identifier, :policy_identifier)

    class InvalidResponse < StandardError; end

    def self.call(...) = new(...).call

    def initialize(account:, snapshot:, llm: Llm::Request)
      @account = account
      @snapshot = snapshot
      @llm = llm
    end

    # @spec OPERATIONAL-SUPERVISOR-005, OPERATIONAL-SUPERVISOR-006
    def call
      validate_snapshot!
      response = llm.call(account:, prompt:, timeout: TIMEOUT, response_validator: method(:response_contract_valid?))
      raise InvalidResponse, "supervisor analysis request failed" unless response.respond_to?(:success?) && response.success?

      Result.new(findings: parse_findings(response.output), model_identifier: model_identifier(response),
        prompt_identifier: PROMPT_IDENTIFIER, policy_identifier: POLICY_IDENTIFIER)
    rescue JSON::ParserError
      reject!("invalid_json")
    rescue InvalidResponse
      reject!("invalid_response")
    end

    private

    attr_reader :account, :llm, :snapshot

    def prompt
      <<~PROMPT
        You analyze a sanitized operational snapshot. Classify delivery-health patterns from the supplied typed facts only.
        Do not infer missing content, request raw source material, or recommend any action outside the catalog.

        Return exactly one JSON object with this schema and no Markdown fencing:
        {
          "findings": [{
            "category": "conversion|cost|guardrail|queue_starvation|rework|stage_age",
            "severity": "info|warning|urgent",
            "affected_project_ids": [1],
            "target_ids": { "project_ids": [1] },
            "evidence": { "metric_names": ["queue_starvation"] },
            "recommendation": "#{RECOMMENDATION_CATALOG.join('|')}"
          }]
        }

        Every project ID must be an included project ID. Every evidence metric must be in the snapshot. The recommendation is advisory and grants no authority.

        #{JSON.generate(snapshot_payload)}
      PROMPT
    end

    def snapshot_payload
      {
        snapshot: {
          id: snapshot.id,
          captured_at: snapshot.captured_at.utc.iso8601,
          included_project_ids: snapshot.included_project_ids,
          digest: snapshot.digest,
          metric_provenance: snapshot.metric_provenance
        }
      }
    end

    def response_contract_valid?(response)
      response.respond_to?(:success?) && response.success? && parse_findings(response.output)
      true
    rescue InvalidResponse, JSON::ParserError
      false
    end

    def parse_findings(output)
      payload = JSON.parse(output.to_s).deep_stringify_keys
      raise InvalidResponse, "supervisor analysis must return findings" unless exact_hash?(payload, "findings")
      raise InvalidResponse, "supervisor analysis findings must be an array" unless payload["findings"].is_a?(Array)
      raise InvalidResponse, "supervisor analysis returned too many findings" if payload["findings"].size > snapshot.included_project_ids.size

      payload["findings"].map { parse_finding(_1) }
    end

    def parse_finding(finding)
      required = %w[category severity affected_project_ids target_ids evidence recommendation]
      raise InvalidResponse, "supervisor analysis finding has unsupported fields" unless exact_hash?(finding, *required)
      raise InvalidResponse, "supervisor analysis category is unknown" unless SupervisorIncident::CATEGORIES.include?(finding["category"])
      raise InvalidResponse, "supervisor analysis severity is unknown" unless SupervisorIncident::SEVERITIES.include?(finding["severity"])
      raise InvalidResponse, "supervisor analysis recommendation is unknown" unless RECOMMENDATION_CATALOG.include?(finding["recommendation"])

      affected_project_ids = project_ids!(finding["affected_project_ids"])
      target_ids = target_ids!(finding["target_ids"])
      evidence = evidence!(finding["evidence"])
      Finding.new(finding["category"], finding["severity"], affected_project_ids, target_ids, evidence, finding["recommendation"])
    end

    def project_ids!(project_ids)
      valid_project_ids!(project_ids)
      project_ids
    end

    def target_ids!(target_ids)
      raise InvalidResponse, "supervisor analysis targets are malformed" unless exact_hash?(target_ids, "project_ids")

      project_ids = target_ids["project_ids"]
      valid_project_ids!(project_ids)
      { "project_ids" => project_ids }
    end

    def valid_project_ids!(project_ids)
      raise InvalidResponse, "supervisor analysis targets are malformed" unless project_ids.is_a?(Array) && project_ids.any? && project_ids.all? { _1.is_a?(Integer) && _1.positive? } && project_ids.uniq.size == project_ids.size
      raise InvalidResponse, "supervisor analysis targets are not snapshot members" unless project_ids.all? { snapshot_project_ids.include?(_1) }
      raise InvalidResponse, "supervisor analysis targets are unauthorized" unless project_ids.all? { enabled_project_ids.include?(_1) }
    end

    def evidence!(evidence)
      raise InvalidResponse, "supervisor analysis evidence is malformed" unless exact_hash?(evidence, "metric_names")

      names = evidence["metric_names"]
      raise InvalidResponse, "supervisor analysis evidence is malformed" unless names.is_a?(Array) && names.any? && names.all?(String) && names.uniq.size == names.size
      raise InvalidResponse, "supervisor analysis evidence references an unknown metric" unless names.all? { snapshot_metric_names.include?(_1) }

      { "metric_names" => names }
    end

    def validate_snapshot!
      raise InvalidResponse, "supervisor snapshot does not belong to account" unless snapshot.account_id == account.id
      raise InvalidResponse, "supervisor snapshot is invalid" unless snapshot.valid?
    end

    def model_identifier(response)
      identifier = response.respond_to?(:model) ? response.model.to_s : ""
      valid = identifier.present? && identifier.length <= SupervisorIncident::PROVENANCE_IDENTIFIER_LIMIT &&
        identifier.match?(SupervisorIncident::PROVENANCE_IDENTIFIER_FORMAT)
      raise InvalidResponse, "supervisor analysis model identity is invalid" unless valid

      identifier
    end

    def reject!(reason)
      Rails.logger.warn(message: "operational_supervisor.analysis_rejected", account_id: account.id,
        snapshot_id: snapshot.id, reason:)
      raise InvalidResponse, "supervisor analysis was rejected"
    end

    def snapshot_project_ids = @snapshot_project_ids ||= snapshot.included_project_ids.to_set
    def snapshot_metric_names = @snapshot_metric_names ||= snapshot.digest.fetch("metrics").pluck("name").to_set

    def enabled_project_ids
      @enabled_project_ids ||= account.projects.where(id: snapshot.included_project_ids).filter_map do |project|
        project.id if FeatureFlags.enabled?(:operational_supervisor, project:)
      end.to_set
    end

    def exact_hash?(value, *keys) = value.is_a?(Hash) && value.keys.sort == keys.sort
  end
end
