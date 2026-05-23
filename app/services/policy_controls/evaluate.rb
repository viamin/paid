# frozen_string_literal: true

module PolicyControls
  class Evaluate
    POLICY_TYPE = "execution"
    POLICY_KEY = "agent_execution"
    SERVICE_CONTAINER_MODE_ALLOW_ATTACHED = "allow_attached"
    SERVICE_CONTAINER_MODE_ALLOWLIST = "allowlist"
    SERVICE_CONTAINER_MODE_NONE = "none"

    Result = Data.define(
      :allowed,
      :paused,
      :reason,
      :sanitized_prompt,
      :risk_score,
      :violations,
      :approval,
      :classification,
      :redaction,
      :controls,
      :context,
      :policy_metadata,
      :matched_environment_controls,
      :matched_risk_rules,
      :matched_approval_rules,
      :simulation
    ) do
      def to_h
        {
          "allowed" => allowed,
          "paused" => paused,
          "reason" => reason,
          "risk_score" => risk_score,
          "violations" => violations,
          "approval" => approval,
          "classification" => classification,
          "redaction" => redaction,
          "controls" => controls,
          "context" => context,
          "policy_metadata" => policy_metadata,
          "matched_environment_controls" => matched_environment_controls,
          "matched_risk_rules" => matched_risk_rules,
          "matched_approval_rules" => matched_approval_rules,
          "simulation" => simulation
        }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue: nil, goal: nil, runner: nil, model: nil, prompt: nil,
      target_branch: nil, service_containers: nil, context: {}, rules: nil, simulation: false)
      @project = project
      @issue = issue
      @goal = goal
      @runner = runner
      @model = model
      @prompt = prompt.to_s
      @target_branch = target_branch
      @service_containers = Array(service_containers)
      @context = normalize_hash(context)
      @rules_override = normalize_hash(rules)
      @simulation = simulation
    end

    def call
      merged_rules = policy_rules
      base_context = build_context
      environment_result = apply_environment_controls(base_context, merged_rules)
      redaction_result = evaluate_redaction(environment_result[:controls])
      evaluation_context = environment_result[:context].merge(redaction_context(redaction_result))
      risk_result = evaluate_risk(evaluation_context, merged_rules)
      approval_result = evaluate_approval(
        evaluation_context.merge("risk_score" => risk_result[:score]),
        merged_rules
      )
      violations = evaluate_violations(
        controls: environment_result[:controls],
        fully_redacted: redaction_result[:details]["fully_redacted"]
      )
      allowed = violations.empty?
      paused = !allowed || approval_result["required"] == true

      Result.new(
        allowed: allowed,
        paused: paused,
        reason: pause_reason(violations, approval_result),
        sanitized_prompt: redaction_result[:sanitized_prompt],
        risk_score: risk_result[:score],
        violations: violations,
        approval: approval_result,
        classification: redaction_result[:classification],
        redaction: redaction_result[:details],
        controls: environment_result[:controls],
        context: evaluation_context,
        policy_metadata: policy_metadata,
        matched_environment_controls: environment_result[:matched],
        matched_risk_rules: risk_result[:matched],
        matched_approval_rules: approval_result["matched_rules"],
        simulation: simulation
      )
    end

    private

    attr_reader :project, :issue, :goal, :runner, :model, :prompt, :target_branch, :service_containers, :context, :rules_override, :simulation

    def policy_rules
      return rules_override if rules_override.present?
      return {} unless policy_version

      normalize_hash(policy_version.rules).deep_merge(normalize_hash(policy_version.parameters))
    end

    def policy_metadata
      {
        "source" => rules_override.present? ? "simulation" : "coordination_policy",
        "policy_key" => POLICY_KEY,
        "coordination_policy_id" => policy_record&.id,
        "coordination_policy_version_id" => policy_version&.id,
        "coordination_policy_version" => policy_version&.version
      }
    end

    def policy_record
      @policy_record ||= CoordinationPolicy
        .active
        .by_type(POLICY_TYPE)
        .where(account: project.account, policy_key: POLICY_KEY)
        .where(project_id: [ nil, project.id ])
        .includes(:current_version)
        .order(Arel.sql("CASE WHEN project_id IS NOT NULL THEN 0 ELSE 1 END"), id: :desc)
        .find { |candidate| candidate.current_version.present? }
    end

    def policy_version
      policy_record&.current_version
    end

    def build_context
      {
        "repo" => project.full_name,
        "branch" => target_branch.presence || project.default_branch,
        "goal" => goal.to_s.presence,
        "issue_labels" => Array(issue&.labels).map(&:to_s),
        "change_surface" => Array(context["change_surface"]).map(&:to_s),
        "regulated" => ActiveModel::Type::Boolean.new.cast(context["regulated"]),
        "runner_key" => runner&.runner_key,
        "direct_outbound" => runner&.requires_direct_outbound? == true,
        "model_id" => model&.model_id,
        "model_tier" => model&.tier
      }.compact.merge(context)
    end

    def apply_environment_controls(base_context, rules)
      controls = normalize_hash(rules["controls"])
      matched = Array(rules["environment_controls"]).filter_map do |rule|
        normalized_rule = normalize_hash(rule)
        next unless ContextMatcher.matches?(conditions: normalized_rule["conditions"], context: base_context)

        controls = controls.deep_merge(normalize_hash(normalized_rule["controls"]))
        normalized_rule["environment"] || normalized_rule["name"] || "unnamed"
      end

      resolved_context = matched.empty? ? base_context : base_context.merge("environment" => matched.last)
      { controls:, context: resolved_context, matched: matched }
    end

    def evaluate_redaction(controls)
      redaction_controls = normalize_hash(controls["prompt_redaction"])
      return empty_redaction(prompt) unless redaction_controls["enabled"] == true

      redaction = Knowledge::Redaction::Redactor.call(text: prompt)
      {
        sanitized_prompt: redaction.clean_text,
        classification: classify_redaction(redaction, redaction_controls),
        details: {
          "enabled" => true,
          "redacted" => redaction.redacted?,
          "fully_redacted" => redaction.fully_redacted?,
          "match_types" => redaction.redactions.map(&:pattern).map(&:to_s).uniq
        }
      }
    end

    def empty_redaction(text)
      {
        sanitized_prompt: text,
        classification: [],
        details: {
          "enabled" => false,
          "redacted" => false,
          "fully_redacted" => false,
          "match_types" => []
        }
      }
    end

    def classify_redaction(redaction, controls)
      return [] unless controls["classify"] == true

      labels = redaction.redactions.map(&:pattern).map { |pattern| "contains:#{pattern}" }.uniq
      labels << "fully_redacted" if redaction.fully_redacted?
      labels
    end

    def redaction_context(redaction_result)
      {
        "classification" => redaction_result[:classification],
        "fully_redacted" => redaction_result[:details]["fully_redacted"]
      }
    end

    def evaluate_risk(evaluation_context, rules)
      matched = Array(rules["risk_rules"]).filter_map do |rule|
        normalized_rule = normalize_hash(rule)
        next unless ContextMatcher.matches?(conditions: normalized_rule["conditions"], context: evaluation_context)

        normalized_rule.slice("name", "score", "labels")
      end

      score = matched.map { |rule| rule["score"].to_i }.max || 0
      { score:, matched: matched }
    end

    def evaluate_approval(evaluation_context, rules)
      matched = Array(rules["approval_rules"]).filter_map do |rule|
        normalized_rule = normalize_hash(rule)
        next unless ContextMatcher.matches?(conditions: normalized_rule["conditions"], context: evaluation_context)

        workflow = normalize_hash(normalized_rule["workflow"])
        next if workflow.empty?

        normalized_rule.merge("workflow" => workflow)
      end

      required = matched.any? { |rule| rule.dig("workflow", "required") == true }
      approvers = matched.flat_map { |rule| Array(rule.dig("workflow", "approvers")) }.map(&:to_s).uniq
      reason = matched.filter_map { |rule| rule.dig("workflow", "reason").presence }.first

      {
        "required" => required,
        "approvers" => approvers,
        "reason" => reason,
        "matched_rules" => matched.map { |rule| rule["name"] || rule.dig("workflow", "reason") || "approval_rule" }
      }
    end

    def evaluate_violations(controls:, fully_redacted:)
      violations = []
      violations << "runner_not_allowed" if runner_disallowed?(controls)
      violations << "model_not_allowed" if model_disallowed?(controls)
      violations << "model_tier_exceeds_maximum" if model_tier_disallowed?(controls)
      violations << "network_access_not_allowed" if network_disallowed?(controls)
      violations << "service_container_not_allowed" if service_container_disallowed?(controls)
      violations << "prompt_fully_redacted" if prompt_blocked?(controls, fully_redacted)
      violations
    end

    def runner_disallowed?(controls)
      allowlist = Array(controls["runner_allowlist"]).map(&:to_s)
      return false if allowlist.empty?
      return false unless runner

      !allowlist.include?(runner.runner_key.to_s)
    end

    def model_disallowed?(controls)
      allowlist = Array(controls["model_allowlist"]).map(&:to_s)
      return false if allowlist.empty?
      return false unless model

      !allowlist.include?(model.model_id.to_s)
    end

    def model_tier_disallowed?(controls)
      max_tier = controls["max_model_tier"].to_s
      return false if max_tier.blank? || model&.tier.blank?

      tier_index(model.tier) > tier_index(max_tier)
    end

    def network_disallowed?(controls)
      return false unless runner&.requires_direct_outbound?

      controls["network_access"].to_s == "restricted"
    end

    def service_container_disallowed?(controls)
      restrictions = normalize_hash(controls["service_containers"])
      mode = restrictions["mode"].to_s
      return false if mode.blank? || service_containers.empty?

      case mode
      when SERVICE_CONTAINER_MODE_NONE
        true
      when SERVICE_CONTAINER_MODE_ALLOW_ATTACHED
        false
      when SERVICE_CONTAINER_MODE_ALLOWLIST
        allowlist = Array(restrictions["allowlist"]).map(&:to_s)
        service_containers.any? do |container|
          !allowlist.include?(container.name.to_s) && !allowlist.include?(container.id.to_s)
        end
      else
        false
      end
    end

    def prompt_blocked?(controls, fully_redacted)
      redaction_controls = normalize_hash(controls["prompt_redaction"])
      return false unless redaction_controls["enabled"] == true
      return false unless redaction_controls["block_fully_redacted"] == true

      fully_redacted == true
    end

    def pause_reason(violations, approval_result)
      return "Policy approval required: #{approval_result["reason"] || "matched approval workflow"}" if violations.empty? && approval_result["required"] == true
      return "Policy blocked execution: #{violations.join(', ')}" if violations.any?

      nil
    end

    def tier_index(tier)
      LlmModel::TIERS.index(tier.to_s) || -1
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.deep_stringify_keys
    end
  end
end
