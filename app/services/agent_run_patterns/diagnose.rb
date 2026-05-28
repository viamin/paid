# frozen_string_literal: true

require "json"

module AgentRunPatterns
  class Diagnose
    DEFAULT_MODEL = "claude-sonnet-4-6"
    MIN_CONFIDENCE = 0.55
    TIMEOUT = 45
    PROMPT = <<~PROMPT
      You are diagnosing recurring Paid agent-run failures.

      Return exactly one JSON object with these keys:
      - root_cause: short free-text string for humans
      - confidence: number between 0.0 and 1.0
      - proposed_action: one of %{actions}
      - action_target: object with:
        - type: one of "account", "project", "runner", "runner_field"
        - id: string or null
        - field_name: string or null
      - evidence_pointers: array of pointer strings copied exactly from the evidence list

      Rules:
      - Choose only from the allowed proposed_action enum.
      - Use only the provided evidence.
      - If evidence is weak, lower confidence.
      - Prefer the narrowest valid target.
      - For clear_runner_field, set action_target.type to "runner_field" and include field_name.
      - Do not include markdown, prose, or extra keys.

      Pattern context:
      %{pattern_context}

      Available target ids:
      %{target_context}

      Evidence:
      %{evidence_lines}
    PROMPT

    ROOT_CAUSE_CATEGORIES = {
      llm_provider: {
        patterns: [
          /no llm provider/i,
          /provider.*error/i,
          /model.*not.*found/i,
          /api.*key.*invalid/i,
          /authentication.*fail/i,
          /quota.*exceeded/i,
          /context.*length.*exceed/i,
          /token.*limit.*exceed/i
        ],
        label: "LLM Provider Error"
      },
      github_api: {
        patterns: [
          /github.*api.*error/i,
          /rate.?limit/i,
          /token.*expired/i,
          /oauth.*session.*expired/i,
          /permission.*denied/i,
          /branch.*protection/i,
          /merge.*conflict/i
        ],
        label: "GitHub API Error"
      },
      container: {
        patterns: [
          /container.*error/i,
          /docker.*error/i,
          /oci.*runtime.*error/i,
          /cannot allocate memory/i,
          /no space left on device/i,
          /container.*exit/i,
          /exec format error/i
        ],
        label: "Container Error"
      },
      timeout: {
        patterns: [
          /timeout/i,
          /timed?\s*out/i,
          /deadline.*exceeded/i,
          /execution.*expired/i
        ],
        label: "Timeout"
      }
    }.freeze

    class Diagnosis < Data.define(
      :root_cause,
      :confidence,
      :proposed_action,
      :action_target,
      :evidence_pointers
    )
      def unknown?
        root_cause == "Unknown"
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(pattern, account:, allow_llm: true)
      @pattern = pattern
      @account = account
      @allow_llm = allow_llm
    end

    def call
      evidence_entries = extract_evidence_entries
      return fallback_diagnosis(evidence_entries) if evidence_entries.empty?
      return fallback_diagnosis(evidence_entries) unless allow_llm

      llm_diagnosis = diagnose_with_llm(evidence_entries)
      llm_diagnosis || fallback_diagnosis(evidence_entries)
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "agent_run_patterns.diagnose_llm_failed",
        account_id: account.id,
        fingerprint: fingerprint,
        error_class: e.class.name,
        error: e.message
      )
      fallback_diagnosis(evidence_entries)
    end

    private

    attr_reader :account, :allow_llm, :pattern

    def diagnose_with_llm(evidence_entries)
      response = AgentHarness.send_message(
        prompt_for(evidence_entries),
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )

      return log_and_fallback("llm_unsuccessful_response") unless response.success?

      parsed = parse_json(response.output)
      return log_and_fallback("invalid_json_output", raw_output: response.output) unless parsed

      validate_llm_diagnosis(parsed)
    end

    def parse_json(output)
      cleaned = output.to_s.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
      return if cleaned.blank?

      JSON.parse(cleaned)
    rescue JSON::ParserError
      nil
    end

    def validate_llm_diagnosis(payload)
      confidence = Float(payload.fetch("confidence"))
      return log_and_fallback("invalid_confidence", raw_output: payload) unless confidence.between?(0.0, 1.0)
      return log_and_fallback("low_confidence", raw_output: payload) if confidence < MIN_CONFIDENCE

      action = payload.fetch("proposed_action").to_s
      unless RemediationDecision::PROPOSED_ACTIONS.include?(action)
        return log_and_fallback("invalid_proposed_action", raw_output: payload)
      end

      evidence_pointers = Array(payload["evidence_pointers"]).map(&:to_s).reject(&:blank?)
      if evidence_pointers.empty? || (evidence_pointers - allowed_pointers).any?
        return log_and_fallback("invalid_evidence_pointers", raw_output: payload)
      end

      root_cause = payload.fetch("root_cause").to_s.strip
      return log_and_fallback("blank_root_cause", raw_output: payload) if root_cause.blank?

      action_target = normalize_action_target(action, payload["action_target"])
      return log_and_fallback("invalid_action_target", raw_output: payload) unless action_target

      Diagnosis.new(
        root_cause: root_cause,
        confidence: confidence.round(3),
        proposed_action: action,
        action_target: action_target,
        evidence_pointers: evidence_pointers
      )
    rescue KeyError, ArgumentError, TypeError
      log_and_fallback("invalid_structured_output", raw_output: payload)
    end

    def normalize_action_target(action, raw_target)
      target = raw_target.is_a?(Hash) ? raw_target.deep_stringify_keys : {}

      case action
      when "notify"
        { "type" => "account", "id" => account.id.to_s }
      when "file_issue"
        project_id = validated_id(target["id"], available_project_ids)
        return unless project_id

        { "type" => "project", "id" => project_id }
      when "mark_runner_unavailable", "disable_runner_fallback"
        runner_id = validated_id(target["id"], available_runner_ids)
        return unless runner_id

        { "type" => "runner", "id" => runner_id }
      when "clear_runner_field"
        runner_id = validated_id(target["id"], available_runner_ids)
        field_name = target["field_name"].to_s.strip
        return if runner_id.blank? || field_name.blank?

        { "type" => "runner_field", "id" => runner_id, "field_name" => field_name }
      end
    end

    def validated_id(value, allowed_ids)
      candidate = value.to_s
      return if candidate.blank?

      candidate if allowed_ids.include?(candidate)
    end

    def fallback_diagnosis(evidence_entries)
      matches = classify_errors(evidence_entries)
      return unknown_diagnosis if matches.empty?

      best_match = matches.max_by { |_, data| data[:score] }
      category_key = best_match.first
      category = ROOT_CAUSE_CATEGORIES.fetch(category_key)

      Diagnosis.new(
        root_cause: category[:label],
        confidence: [ best_match.last[:score].to_f / evidence_entries.size, 1.0 ].min.round(3),
        proposed_action: "notify",
        action_target: { "type" => "account", "id" => account.id.to_s },
        evidence_pointers: Array(matches[category_key][:pointers]).presence || [ evidence_entries.first.fetch(:pointer) ]
      )
    end

    def unknown_diagnosis
      Diagnosis.new(
        root_cause: "Unknown",
        confidence: 0.0,
        proposed_action: "notify",
        action_target: { "type" => "account", "id" => account.id.to_s },
        evidence_pointers: []
      )
    end

    def classify_errors(evidence_entries)
      matches = Hash.new { |hash, key| hash[key] = { score: 0, pointers: [] } }

      evidence_entries.each do |entry|
        ROOT_CAUSE_CATEGORIES.each do |category_key, config|
          next unless config[:patterns].any? { |pattern_match| entry[:text].match?(pattern_match) }

          matches[category_key][:score] += 1
          matches[category_key][:pointers] << entry[:pointer]
        end
      end

      matches.transform_values { |data| data[:score].positive? ? data : nil }.compact
    end

    def extract_evidence_entries
      evidence_bundle = EvidenceBundle.from_payload(pattern.details[:evidence_bundle])
      entries = evidence_bundle.documents_with_pointers
      return entries if entries.any?

      legacy_messages(pattern.details).filter_map.with_index do |message, index|
        next if message.blank?

        { pointer: "legacy_messages[#{index}]", text: message }
      end
    end

    def allowed_pointers
      @allowed_pointers ||= extract_evidence_entries.map { |entry| entry[:pointer] }
    end

    def legacy_messages(details)
      Array(details[:error_messages] || details[:sample_messages])
    end

    def prompt_for(evidence_entries)
      format(
        PROMPT,
        actions: RemediationDecision::PROPOSED_ACTIONS.to_json,
        pattern_context: {
          fingerprint: fingerprint,
          goal: pattern.goal,
          type: pattern.type,
          severity: pattern.severity,
          details: pattern.details.except(:evidence_bundle)
        }.to_json,
        target_context: {
          account_id: account.id.to_s,
          project_ids: available_project_ids,
          runner_ids: available_runner_ids
        }.to_json,
        evidence_lines: evidence_entries.map { |entry|
          "#{entry[:pointer]}: #{entry[:text].truncate(500)}"
        }.join("\n")
      )
    end

    def fingerprint
      pattern.details[:fingerprint].to_s
    end

    def available_project_ids
      Array(evidence_bundle.aggregate_stats[:distinct_project_ids]).map(&:to_s)
    end

    def available_runner_ids
      Array(evidence_bundle.aggregate_stats[:distinct_runner_ids]).map(&:to_s)
    end

    def evidence_bundle
      @evidence_bundle ||= EvidenceBundle.from_payload(pattern.details[:evidence_bundle])
    end

    def log_and_fallback(reason, raw_output: nil)
      Rails.logger.warn(
        message: "agent_run_patterns.diagnose_fell_back",
        account_id: account.id,
        fingerprint: fingerprint,
        reason: reason,
        raw_output: raw_output
      )
      nil
    end
  end
end
