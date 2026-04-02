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
  #     mutation_count: 3
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

    STRATEGIES = %w[refinement restructuring simplification expansion].freeze

    Mutation = Struct.new(:template, :strategy, :reasoning, :expected_improvement, keyword_init: true)

    class << self
      def call(prompt:, quality_metrics: [], sample_outputs: {}, mutation_count: 3, strategies: STRATEGIES)
        new(
          prompt: prompt,
          quality_metrics: quality_metrics,
          sample_outputs: sample_outputs,
          mutation_count: mutation_count,
          strategies: strategies
        ).mutate
      end
    end

    def initialize(prompt:, quality_metrics: [], sample_outputs: {}, mutation_count: 3, strategies: STRATEGIES)
      @prompt = prompt
      @quality_metrics = quality_metrics
      @sample_outputs = sample_outputs
      @mutation_count = mutation_count.clamp(MIN_MUTATION_COUNT, MAX_MUTATION_COUNT)
      @strategies = strategies & STRATEGIES
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
      return nil unless response.success?

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
        1. Preserve all template variables (#{variable_names.join(', ')}) — use the exact {{variable_name}} syntax
        2. Be a complete, standalone prompt template (not a diff or partial edit)
        3. Apply one of the requested strategies: #{@strategies.join(', ')}
        4. Address specific weaknesses identified in the performance data

        Respond with ONLY valid JSON in this exact format (no markdown fences, no explanation):
        {"mutations":[{"template":"improved prompt text","strategy":"one of #{@strategies.join('/')}","reasoning":"what problem this addresses","expected_improvement":"why this should perform better"}]}
      PROMPT
    end

    def current_template
      @prompt.current_version.template.truncate(MAX_TEMPLATE_INPUT, omission: "\n[truncated]")
    end

    def variable_names
      @prompt.current_version.variables.presence || []
    end

    def variables_section
      names = variable_names
      return "" if names.empty?

      "## Template Variables\n#{names.join(', ')}\n"
    end

    def system_prompt_section
      sp = @prompt.current_version.system_prompt
      return "" if sp.blank?

      "## System Prompt\n```\n#{sp.truncate(MAX_TEMPLATE_INPUT, omission: "\n[truncated]")}\n```\n"
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

    def sample_outputs_section
      successes = truncated_samples(@sample_outputs[:successes])
      failures = truncated_samples(@sample_outputs[:failures])

      return "" if successes.empty? && failures.empty?

      section = "## Sample Outputs\n"

      if successes.any?
        section += "\n### Successful Runs (score > 0.8)\n"
        successes.each_with_index { |s, i| section += "#{i + 1}. #{s}\n" }
      end

      if failures.any?
        section += "\n### Failed Runs (score < 0.5)\n"
        failures.each_with_index { |s, i| section += "#{i + 1}. #{s}\n" }
      end

      section
    end

    def truncated_samples(samples)
      return [] if samples.blank?

      samples.first(MAX_SAMPLES).map { |s| s.to_s.truncate(MAX_SAMPLE_OUTPUT, omission: " [truncated]") }
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

      mutations_data.filter_map { |m| build_mutation(m) }
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
      template = data["template"].to_s.strip
      strategy = data["strategy"].to_s.strip
      reasoning = data["reasoning"].to_s.strip
      expected_improvement = data["expected_improvement"].to_s.strip

      return nil if template.blank?
      return nil if template.length > MAX_GENERATED_TEMPLATE_LENGTH
      return nil unless valid_variables?(template)
      return nil unless STRATEGIES.include?(strategy)

      Mutation.new(
        template: template,
        strategy: strategy,
        reasoning: reasoning,
        expected_improvement: expected_improvement
      )
    end

    def valid_variables?(template)
      required = variable_names
      return true if required.empty?

      required.all? { |var| template.include?("{{#{var.delete_prefix('{{').delete_suffix('}}')}}}") }
    end
  end
end
