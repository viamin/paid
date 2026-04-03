# frozen_string_literal: true

module PromptEvolution
  # Generates improved prompt variants by analyzing performance data from
  # sampled runs. Uses an LLM to propose targeted mutations based on what
  # worked, what failed, and which strategies are most likely to help.
  #
  # @example
  #   mutations = PromptEvolution::Mutate.call(
  #     prompt: prompt,
  #     quality_metrics: metrics,
  #     sample_outputs: { successes: [...], failures: [...] },
  #     options: { mutation_count: 3 }
  #   )
  #   mutations.each { |m| prompt.create_version!(template: m.template, ...) }
  class Mutate
    include Llm::OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 60
    MAX_TEMPLATE_INPUT = 10_000
    MAX_SAMPLE_OUTPUT = 2_000
    MAX_SAMPLES = 3
    MAX_MUTATION_COUNT = 5
    MIN_MUTATION_COUNT = 1
    MAX_GENERATED_TEMPLATE_LENGTH = 50_000
    MAX_ERROR_OUTPUT = 500

    STRATEGIES = %w[refinement restructuring simplification expansion].freeze

    Mutation = Struct.new(:template, :strategy, :reasoning, :expected_improvement, keyword_init: true)

    class << self
      def call(prompt:, quality_metrics: [], sample_outputs: {}, options: {})
        new(
          prompt: prompt,
          quality_metrics: quality_metrics,
          sample_outputs: sample_outputs,
          options: options
        ).mutate
      end
    end

    def initialize(prompt:, quality_metrics: [], sample_outputs: {}, options: {})
      @prompt = prompt
      @quality_metrics = quality_metrics
      @sample_outputs = sample_outputs
      raw_count = options.fetch(:mutation_count, options.fetch("mutation_count", 3))
      @mutation_count = Integer(raw_count).clamp(MIN_MUTATION_COUNT, MAX_MUTATION_COUNT)
      raw_strategies = options.fetch(:strategies, options.fetch("strategies", STRATEGIES))
      @strategies = Array(raw_strategies) & STRATEGIES
      validate!
    end

    def mutate
      response = request_mutations
      return [] if response.nil?

      parse_mutations(response)
    end

    private

    def validate!
      raise ArgumentError, "prompt must have a current version" unless @prompt.current_version
      raise ArgumentError, "strategies must include at least one of: #{STRATEGIES.join(', ')}" if @strategies.empty?
    end

    def request_mutations
      response = AgentHarness.send_message(
        build_prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT
      )
      unless response.success?
        Rails.logger.warn(
          message: "prompt_evolution.mutate_unsuccessful_response",
          prompt_id: @prompt.id,
          exit_code: response.exit_code,
          error_detail: truncated_error(response)
        )
        return nil
      end

      response.output
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "prompt_evolution.mutate_failed",
        prompt_id: @prompt.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    def truncated_error(response)
      raw = response.error.to_s
      return nil if raw.blank?

      # Redact before truncating to avoid splitting secrets mid-match
      redact(raw).truncate(MAX_ERROR_OUTPUT, omission: " [truncated]")
    end

    def redact(text)
      return text if text.blank?

      Knowledge::Redaction::Redactor.call(text: text).clean_text
    end

    def build_prompt
      <<~PROMPT
        You are a prompt engineering expert. Analyze the following prompt and its performance data, then generate #{@mutation_count} improved variant(s).

        ## Current Prompt Template
        ```
        #{current_template}
        ```

        #{variables_section}
        #{system_prompt_section}
        #{performance_section}
        #{sample_outputs_section}
        #{strategies_section}

        ## Instructions
        Generate exactly #{@mutation_count} improved prompt variant(s). Each variant must:
        #{variables_preservation_instruction}- Be a complete, standalone prompt template (not a diff or partial edit)
        - Apply one of the requested strategies: #{@strategies.join(', ')}
        - Address specific weaknesses identified in the performance data

        Respond with ONLY valid JSON in this exact format (no markdown fences, no explanation):
        {"mutations":[{"template":"improved prompt text","strategy":"one of #{@strategies.join('/')}","reasoning":"what problem this addresses","expected_improvement":"why this should perform better"}]}
      PROMPT
    end

    def current_template
      # Redact before truncating to avoid splitting secrets mid-match
      redact(@prompt.current_version.template).truncate(MAX_TEMPLATE_INPUT, omission: "\n[truncated]")
    end

    def variable_names
      @variable_names ||= Array(@prompt.current_version.variables).filter_map do |variable|
        name =
          if variable.is_a?(Hash)
            variable["name"] || variable[:name]
          else
            variable
          end

        normalized = name.to_s.strip
        normalized if normalized.present?
      end
    end

    def variables_preservation_instruction
      names = variable_names
      return "" if names.empty?

      "- Preserve all template variables (#{names.join(', ')}) — use the exact {{variable_name}} syntax\n        "
    end

    def variables_section
      names = variable_names
      return "" if names.empty?

      "## Template Variables\n#{names.join(', ')}\n"
    end

    def system_prompt_section
      sp = @prompt.current_version.system_prompt
      return "" if sp.blank?

      # Redact before truncating to avoid splitting secrets mid-match
      safe_sp = redact(sp).truncate(MAX_TEMPLATE_INPUT, omission: "\n[truncated]")
      "## System Prompt\n```\n#{safe_sp}\n```\n"
    end

    def performance_section
      return "## Performance Data\nNo quality metrics available yet.\n" if @quality_metrics.empty?

      scores = @quality_metrics.filter_map(&:composite_score)
      return "## Performance Data\nNo composite scores available yet.\n" if scores.empty?

      avg = (scores.sum / scores.size).round(4)
      min = scores.min.round(4)
      max = scores.max.round(4)

      failure_modes = identify_failure_modes

      section = <<~SECTION
        ## Performance Data
        - Sample size: #{scores.size}
        - Average quality score: #{avg}
        - Score range: #{min} — #{max}
      SECTION

      if failure_modes.any?
        section += "\n## Common Failure Modes\n"
        failure_modes.each { |mode| section += "- #{mode}\n" }
      end

      section
    end

    def identify_failure_modes
      modes = []

      score_groups = @quality_metrics.select(&:scores).flat_map { |m| m.scores.to_a }
      grouped = score_groups.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

      grouped.each do |key, values|
        avg = values.sum(&:to_f) / values.size
        modes << "Low #{key.humanize.downcase} (avg: #{avg.round(2)})" if avg < 0.5
      end

      modes
    end

    def sample_outputs_for(key)
      return nil unless @sample_outputs.respond_to?(:[])

      @sample_outputs[key] || @sample_outputs[key.to_s]
    end

    def sample_outputs_section
      successes = truncated_samples(sample_outputs_for(:successes))
      failures = truncated_samples(sample_outputs_for(:failures))

      return "" if successes.empty? && failures.empty?

      section = "## Sample Outputs\n"

      if successes.any?
        section += "\n### Successful Runs\n"
        successes.each_with_index { |s, i| section += "#{i + 1}. #{s}\n" }
      end

      if failures.any?
        section += "\n### Failed Runs\n"
        failures.each_with_index { |s, i| section += "#{i + 1}. #{s}\n" }
      end

      section
    end

    def truncated_samples(samples)
      return [] if samples.blank?

      # Redact before truncating to avoid splitting secrets mid-match
      samples.first(MAX_SAMPLES).map { |s| redact(s.to_s).truncate(MAX_SAMPLE_OUTPUT, omission: " [truncated]") }
    end

    def strategies_section
      <<~SECTION
        ## Mutation Strategies to Apply
        #{strategy_descriptions.join("\n")}
      SECTION
    end

    def strategy_descriptions
      @strategies.map do |strategy|
        case strategy
        when "refinement"
          "- **Refinement**: Make targeted improvements to specific instructions while preserving overall structure"
        when "restructuring"
          "- **Restructuring**: Reorganize the prompt layout for clarity (reorder sections, add headers, improve flow)"
        when "simplification"
          "- **Simplification**: Remove redundant instructions, reduce verbosity, focus on essential guidance"
        when "expansion"
          "- **Expansion**: Add examples, edge case handling, or additional context where the prompt is underspecified"
        end
      end
    end

    def parse_mutations(raw_output)
      cleaned = clean_output(raw_output)
      data = JSON.parse(cleaned)
      mutations_data = data.fetch("mutations") { return [] }
      return [] unless mutations_data.is_a?(Array)

      mutations_data.filter_map { |m| build_mutation(m) }.first(@mutation_count)
    rescue JSON::ParserError => e
      Rails.logger.warn(
        message: "prompt_evolution.mutate_parse_failed",
        prompt_id: @prompt.id,
        error: e.message
      )
      []
    end

    def clean_output(text)
      return "" if text.blank?

      cleaned = text.strip
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

      template = data["template"].to_s.strip
      strategy = data["strategy"].to_s.strip
      reasoning = data["reasoning"].to_s.strip
      expected_improvement = data["expected_improvement"].to_s.strip

      return nil if template.blank?
      return nil if template.length > MAX_GENERATED_TEMPLATE_LENGTH
      return nil unless valid_variables?(template)
      return nil unless @strategies.include?(strategy)

      Mutation.new(
        template: template,
        strategy: strategy,
        reasoning: reasoning,
        expected_improvement: expected_improvement
      )
    end

    def valid_variables?(template)
      required = required_variable_names
      return true if required.empty?

      generated_variables = extract_template_variables(template)
      required.all? { |var| generated_variables.include?(var) }
    end

    def required_variable_names
      names = variable_names
      return names if names.any?

      # Fall back to extracting {{...}} placeholders from the current template
      extract_template_variables(@prompt.current_version.template.to_s)
    end

    def extract_template_variables(template)
      return [] if template.blank?

      template.scan(/\{\{\s*([^{}]+?)\s*\}\}/).flatten.map(&:strip).reject(&:blank?).uniq
    end
  end
end
