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
    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 120

    # Default maximum raw content size sent to the LLM for compression.
    # Content beyond this limit is truncated; metadata records the truncation.
    # Overridden by UserSetting#style_guide_max_raw_bytes at runtime.
    DEFAULT_MAX_RAW_BYTES = 100_000

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
      raw = style_guide.raw_content
      max_bytes = user_settings&.style_guide_max_raw_bytes || DEFAULT_MAX_RAW_BYTES
      @truncated = raw.bytesize > max_bytes
      @max_raw_bytes_used = max_bytes
      raw = raw.byteslice(0, max_bytes).scrub("") if @truncated

      response = AgentHarness.send_message(
        "#{COMPRESSION_PROMPT}\n\n#{raw}",
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
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
      raw_bytes = style_guide.raw_content.bytesize
      compressed_bytes = compressed.bytesize

      meta = {
        "compressed_at" => Time.current.iso8601,
        "model" => DEFAULT_MODEL,
        "raw_length" => raw_bytes,
        "compressed_length" => compressed_bytes,
        "compression_ratio" => (compressed_bytes.to_f / raw_bytes).round(2)
      }
      meta["truncated_at_bytes"] = @max_raw_bytes_used if @truncated
      meta
    end

    def user_settings
      return @user_settings if defined?(@user_settings)

      project = style_guide.project
      @user_settings = project ? AgentRuns::UserSettingsResolver.call(project: project, strict: false) : nil
    end
  end
end
