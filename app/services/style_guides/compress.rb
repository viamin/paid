# frozen_string_literal: true

module StyleGuides
  # Compresses raw style guide content into an LLM-friendly format.
  # Implements the AGD (AI-Generated Determinism) pattern: uses the LLM
  # once to compress, then stores the deterministic output for runtime use.
  #
  # @example
  #   StyleGuides::Compress.call(style_guide: style_guide)
  class CompressionError < StandardError; end

  class Compress
    COMPRESSION_PROMPT = <<~PROMPT
      You are a technical writing assistant. Compress the following coding style guide into a concise, LLM-friendly format.

      Rules:
      - Keep all concrete rules (naming conventions, formatting, patterns to use/avoid)
      - Remove verbose explanations, examples that restate the rule, and motivational text
      - Use terse bullet points grouped by category
      - Preserve code snippets only when they define a pattern (e.g. preferred import style)
      - Target roughly 30-50% of the original length
      - Output plain text with markdown formatting

      Style guide to compress:
    PROMPT

    attr_reader :style_guide

    def initialize(style_guide:)
      @style_guide = style_guide
    end

    def self.call(...)
      new(...).call
    end

    def call
      compressed = compress_content
      metadata = build_metadata(compressed)

      style_guide.update!(
        compressed_content: compressed,
        compression_metadata: metadata
      )

      style_guide
    end

    private

    def compress_content
      response = AgentHarness.send_message(
        "#{COMPRESSION_PROMPT}\n\n#{style_guide.raw_content}",
        provider: :claude,
        dangerous_mode: false
      )

      validate_response!(response)
      response.output
    end

    def validate_response!(response)
      success = !response.respond_to?(:success?) || response.success?
      output = response.output

      return if success && output.present?

      details = [ "success=#{success}" ]
      details << "exit_code=#{response.exit_code.inspect}" if response.respond_to?(:exit_code)

      raise CompressionError, "LLM compression failed or returned empty output (#{details.join(', ')})"
    end

    def build_metadata(compressed)
      {
        compressed_at: Time.current.iso8601,
        raw_length: style_guide.raw_content.length,
        compressed_length: compressed.length,
        compression_ratio: (compressed.length.to_f / style_guide.raw_content.length).round(2)
      }
    end
  end
end
