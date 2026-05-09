# frozen_string_literal: true

class OrchestrationStrategySelector
  Result = Data.define(:strategy, :strategy_version, :scope, :matched_rule_count) do
    delegate :content, :promotion_state, :version, to: :strategy_version
    delegate :decision_type, :name, :selection_rules, :slug, to: :strategy
  end

  SCOPE_PRIORITIES = {
    project: 3,
    account: 2,
    global: 1
  }.freeze

  def self.call(...)
    new(...).call
  end

  def initialize(decision_type:, context: {}, project: nil, account: nil)
    @decision_type = decision_type.to_s
    @context = normalize_hash(context)
    @project = project
    @account = account
  end

  def call
    candidates
      .filter_map { |strategy| build_result(strategy) }
      .max_by { |result| [ SCOPE_PRIORITIES.fetch(result.scope), result.matched_rule_count, result.version, result.strategy.id ] }
  end

  private

  attr_reader :decision_type, :context, :project, :account

  def candidates
    @candidates ||= Strategy
      .active
      .by_decision_type(decision_type)
      .includes(:current_version)
      .select { |strategy| visible_in_scope?(strategy) }
  end

  def visible_in_scope?(strategy)
    case scope_for(strategy)
    when :project
      project.present? && strategy.project_id == project.id
    when :account
      effective_account_id.present? && strategy.account_id == effective_account_id && strategy.project_id.nil?
    when :global
      strategy.global?
    else
      false
    end
  end

  def build_result(strategy)
    version = strategy.current_version
    return nil unless version&.active?
    return nil unless rules_match?(strategy.selection_rules, selection_context)

    Result.new(
      strategy: strategy,
      strategy_version: version,
      scope: scope_for(strategy),
      matched_rule_count: count_rules(strategy.selection_rules)
    )
  end

  def scope_for(strategy)
    return :project if strategy.project_id.present?
    return :account if strategy.account_id.present?

    :global
  end

  def selection_context
    @selection_context ||= begin
      derived = {
        "decision_type" => decision_type,
        "project_id" => project&.id,
        "account_id" => effective_account_id
      }.compact

      context.merge(derived)
    end
  end

  def effective_account_id
    @effective_account_id ||= account&.id || project&.account_id
  end

  def rules_match?(rules, subject)
    normalized_rules = normalize_hash(rules)
    return true if normalized_rules.empty?

    normalized_rules.all? do |key, expected|
      actual = subject[key]
      value_matches?(expected, actual)
    end
  end

  def value_matches?(expected, actual)
    case expected
    when Hash
      actual.is_a?(Hash) && rules_match?(expected, actual)
    when Array
      expected.include?("any") || expected.any? { |value| value_matches?(value, actual) }
    when nil, "any"
      true
    else
      actual.to_s == expected.to_s
    end
  end

  def count_rules(value)
    case value
    when Hash
      value.sum { |_key, nested| count_rules(nested) }
    when Array
      value.size
    else
      1
    end
  end

  def normalize_hash(value)
    return {} unless value.is_a?(Hash)

    value.deep_stringify_keys
  end
end
