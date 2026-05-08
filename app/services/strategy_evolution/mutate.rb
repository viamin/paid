# frozen_string_literal: true

module StrategyEvolution
  class Mutate
    include Llm::OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 60
    MAX_MUTATION_COUNT = 5
    MIN_MUTATION_COUNT = 1
    MAX_ERROR_OUTPUT = 500
    MUTATION_STRATEGIES = %w[refinement risk_reduction throughput observability].freeze

    Mutation = Struct.new(
      :configuration,
      :strategy,
      :reasoning,
      :expected_improvement,
      :diff,
      :provenance,
      keyword_init: true
    )

    def self.call(strategy:, analysis:, options: {})
      new(strategy:, analysis:, options:).call
    end

    def initialize(strategy:, analysis:, options: {})
      @strategy = strategy.deep_symbolize_keys
      @analysis = analysis.deep_symbolize_keys
      raw_count = options.fetch(:mutation_count, options.fetch("mutation_count", 2))
      @mutation_count = Integer(raw_count).clamp(MIN_MUTATION_COUNT, MAX_MUTATION_COUNT)
      raw_strategies = options.fetch(:strategies, options.fetch("strategies", MUTATION_STRATEGIES))
      @mutation_strategies = Array(raw_strategies).map(&:to_s) & MUTATION_STRATEGIES
      validate!
    end

    def call
      response = request_mutations
      return [] if response.nil?

      parse_mutations(response)
    end

    private

    attr_reader :strategy, :analysis, :mutation_count, :mutation_strategies

    PROMPT_SLUG = "evolution.mutate_strategy"

    FALLBACK_PROMPT = <<~PROMPT
      You are evolving an orchestration strategy from historical execution outcomes.

      ## Current Strategy
      ```json
      {{current_strategy_json}}
      ```

      ## Prior Versions
      ```json
      {{prior_versions_json}}
      ```

      ## Historical Outcome Summary
      ```json
      {{performance_json}}
      ```

      ## Successful Samples
      ```json
      {{success_samples_json}}
      ```

      ## Failure Samples
      ```json
      {{failure_samples_json}}
      ```

      ## Mutation Strategies
      {{mutation_strategies_section}}

      ## Instructions
      Generate exactly {{mutation_count}} candidate strategy variants.
      Each candidate must:
      - Return a full strategy configuration object, not a patch
      - Keep the same top-level schema as the current strategy
      - Use one of the allowed mutation strategies: {{strategies_csv}}
      - Target an observed failure mode or guardrail issue

      Respond with ONLY valid JSON:
      {"mutations":[{"configuration":{},"strategy":"one of {{strategies_pipe}}","reasoning":"why this change should help","expected_improvement":"what should improve"}]}
    PROMPT

    def validate!
      raise ArgumentError, "strategy configuration is required" if current_configuration.blank?
      raise ArgumentError, "mutation strategies must not be empty" if mutation_strategies.empty?
    end

    def request_mutations
      response = AgentHarness.send_message(
        build_prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )
      unless response.success?
        Rails.logger.warn(
          message: "strategy_evolution.mutate_unsuccessful_response",
          strategy_type: strategy[:strategy_type],
          account_id: strategy[:account_id],
          exit_code: response.exit_code,
          error_detail: truncated_error(response)
        )
        return nil
      end

      response.output
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "strategy_evolution.mutate_failed",
        strategy_type: strategy[:strategy_type],
        account_id: strategy[:account_id],
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def truncated_error(response)
      raw = response.error.to_s
      return nil if raw.blank?

      Knowledge::Redaction::Redactor.call(text: raw).clean_text.truncate(MAX_ERROR_OUTPUT, omission: " [truncated]")
    end

    def build_prompt
      vars = {
        current_strategy_json: JSON.pretty_generate(current_configuration),
        prior_versions_json: JSON.pretty_generate(Array(analysis[:prior_versions])),
        performance_json: JSON.pretty_generate(analysis.fetch(:performance, {})),
        success_samples_json: JSON.pretty_generate(Array(analysis[:sample_successes])),
        failure_samples_json: JSON.pretty_generate(Array(analysis[:sample_failures])),
        mutation_count: mutation_count,
        mutation_strategies_section: mutation_strategies.map { |name| "- #{name.humanize}" }.join("\n"),
        strategies_csv: mutation_strategies.join(", "),
        strategies_pipe: mutation_strategies.join("/")
      }

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )
    end

    def parse_mutations(raw_output)
      cleaned = clean_output(raw_output)
      parsed = JSON.parse(cleaned)
      mutations = parsed.fetch("mutations") { return [] }
      return [] unless mutations.is_a?(Array)

      mutations.filter_map { |mutation| build_mutation(mutation) }.first(mutation_count)
    rescue JSON::ParserError => e
      Rails.logger.warn(
        message: "strategy_evolution.mutate_parse_failed",
        strategy_type: strategy[:strategy_type],
        account_id: strategy[:account_id],
        error: e.message
      )
      []
    end

    def clean_output(text)
      cleaned = text.to_s.strip
      loop do
        previous = cleaned
        cleaned = strip_markdown_fence(cleaned)
        cleaned = strip_surrounding_quotes(cleaned)
        break if cleaned == previous
      end
      cleaned
    end

    def build_mutation(data)
      return nil unless data.is_a?(Hash)

      configuration = data["configuration"]
      strategy_name = data["strategy"].to_s.strip
      reasoning = data["reasoning"].to_s.strip
      expected_improvement = data["expected_improvement"].to_s.strip
      return nil unless configuration.is_a?(Hash)
      return nil unless mutation_strategies.include?(strategy_name)

      normalized = configuration.deep_stringify_keys
      return nil unless valid_schema?(current_configuration, normalized)

      diff = diff_entries(current_configuration, normalized)
      return nil if diff.empty?

      Mutation.new(
        configuration: normalized,
        strategy: strategy_name,
        reasoning: reasoning,
        expected_improvement: expected_improvement,
        diff: diff,
        provenance: {
          "source_strategy_id" => strategy[:id],
          "source_version" => strategy[:version],
          "decision_summary" => analysis.fetch(:performance, {}).slice(:decision_count, :success_rate, :guardrail_violation_types)
        }
      )
    end

    def current_configuration
      @current_configuration ||= strategy.fetch(:configuration).deep_stringify_keys
    end

    def valid_schema?(current_value, candidate_value)
      case current_value
      when Hash
        return false unless candidate_value.is_a?(Hash)
        return true if current_value.empty?
        return false unless current_value.keys.sort == candidate_value.keys.sort

        current_value.all? { |key, value| valid_schema?(value, candidate_value[key]) }
      when Array
        candidate_value.is_a?(Array)
      when Numeric
        candidate_value.is_a?(Numeric)
      when TrueClass, FalseClass
        candidate_value == true || candidate_value == false
      when String
        candidate_value.is_a?(String)
      when NilClass
        true
      else
        candidate_value.class == current_value.class
      end
    end

    def diff_entries(current_value, candidate_value, path = nil)
      if current_value.is_a?(Hash) && candidate_value.is_a?(Hash)
        current_value.keys.sort.flat_map do |key|
          next_path = [ path, key ].compact.join("/")
          diff_entries(current_value[key], candidate_value[key], next_path)
        end
      else
        current_value == candidate_value ? [] : [ diff_entry(path, current_value, candidate_value) ]
      end
    end

    def diff_entry(path, current_value, candidate_value)
      {
        "path" => "/#{path}",
        "from" => current_value,
        "to" => candidate_value
      }
    end
  end
end
