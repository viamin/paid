# frozen_string_literal: true

module StyleGuideEvolution
  class Mutate
    include Llm::OutputNormalizer

    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 60
    MAX_MUTATION_COUNT = 5
    MIN_MUTATION_COUNT = 1
    MAX_GENERATED_TEMPLATE_LENGTH = PromptEvolution::Mutate::MAX_GENERATED_TEMPLATE_LENGTH
    STRATEGIES = PromptEvolution::Mutate::STRATEGIES

    Mutation = Struct.new(:raw_content, :strategy, :reasoning, :expected_improvement, keyword_init: true)

    def self.call(style_guide:, quality_metrics: [], sample_outputs: {}, options: {})
      new(style_guide:, quality_metrics:, sample_outputs:, options:).mutate
    end

    def initialize(style_guide:, quality_metrics: [], sample_outputs: {}, options: {})
      @style_guide = style_guide
      @quality_metrics = quality_metrics
      @sample_outputs = sample_outputs
      raw_count = options.fetch(:mutation_count, options.fetch("mutation_count", 3))
      @mutation_count = Integer(raw_count).clamp(MIN_MUTATION_COUNT, MAX_MUTATION_COUNT)
      raw_strategies = options.fetch(:strategies, options.fetch("strategies", STRATEGIES))
      @strategies = Array(raw_strategies) & STRATEGIES
    end

    # @spec STYLE-GUIDE-EVOLUTION-007
    def mutate
      response = AgentHarness.send_message(
        build_prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )
      return [] unless response.success? && response.output.present?

      parsed = parse_mutations(response.output)
      Array(parsed[:mutations]).filter_map do |mutation|
        raw_content = mutation[:raw_content].to_s.presence || mutation[:content].to_s.presence
        next if raw_content.blank?
        next if raw_content.length > MAX_GENERATED_TEMPLATE_LENGTH

        Mutation.new(
          raw_content: raw_content,
          strategy: mutation[:strategy].to_s.presence || STRATEGIES.first,
          reasoning: mutation[:reasoning],
          expected_improvement: mutation[:expected_improvement]
        )
      end
    rescue AgentHarness::Error
      []
    end

    private

    def build_prompt
      <<~PROMPT
        You are evolving a coding style guide used by an autonomous coding agent.

        Current style guide:
        #{redact(@style_guide.raw_content)}

        Performance summary:
        #{performance_summary}

        Generate exactly #{@mutation_count} improved full style-guide variants.
        Each variant must be a complete replacement guide, not a diff.
        Allowed strategies: #{@strategies.join(', ')}.

        Respond with JSON only:
        {"mutations":[{"raw_content":"full guide","strategy":"refinement","reasoning":"why","expected_improvement":"impact"}]}
      PROMPT
    end

    def performance_summary
      scores = @quality_metrics.filter_map { |metric| metric[:composite_score] || metric["composite_score"] }
      return "No quality metrics available." if scores.empty?

      avg = (scores.sum.to_f / scores.size).round(4)
      "sample_size=#{scores.size}, avg_quality_score=#{avg}"
    end

    def parse_mutations(text)
      JSON.parse(clean_output(text), symbolize_names: true)
    rescue JSON::ParserError
      {}
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

    def redact(text)
      return text if text.blank?

      Knowledge::Redaction::Redactor.call(text: text).clean_text
    end
  end
end
