# frozen_string_literal: true

module Containers
  # Resolves the Docker agent image for a project based on its detected
  # language/runtime profile (RDR-046 / POLYGLOT-TEST-004).
  #
  # The base image (+BASE_IMAGE+) bundles Ruby, Node, and Python — the
  # runtimes every agent container needs. Projects whose detected languages
  # are a subset of those base runtimes resolve to +BASE_IMAGE+. Projects that
  # require additional runtimes (Go, Rust, Elixir, Swift) resolve to a combo
  # image tag (+paid-agent:<sorted-language-set>+).
  #
  # Chat and knowledge containers always use the base image (via
  # +ImageResolver.base_image+) because they run analysis tooling and LLM
  # calls, not the project's own test suite — they never need project-specific
  # runtimes.
  #
  # Unsupported runtimes (languages outside the RDR-046 target matrix) are
  # ignored by default: the resolver falls back to the base image and exposes
  # the unsupported set via +#unsupported_languages+ for observability. Pass
  # +strict: true+ to raise +UnsupportedRuntimeError+ instead, so callers that
  # must run in the correct image fail loudly (POLYGLOT-TEST-006).
  #
  # @example
  #   Containers::ImageResolver.resolve(project)
  #   # => "paid-agent:elixir-node-python-ruby"
  class ImageResolver
    BASE_IMAGE = "paid-agent:latest"
    IMAGE_PREFIX = "paid-agent"

    # Runtimes bundled in the base image. Every combo image is built +FROM+
    # the base, so these are available regardless of the resolved tag.
    BASE_LANGUAGES = %w[node python ruby].freeze

    # Runtimes that require a dedicated combo image layer on top of the base.
    EXTENDED_LANGUAGES = %w[elixir go rust swift].freeze

    # Maps GitHub-reported / detected language keys to image-layer tokens.
    # JavaScript and TypeScript both map to +node+ since Node satisfies both.
    LANGUAGE_TOKENS = {
      "ruby" => "ruby",
      "javascript" => "node",
      "typescript" => "node",
      "python" => "python",
      "go" => "go",
      "rust" => "rust",
      "elixir" => "elixir",
      "swift" => "swift"
    }.freeze

    SUPPORTED_LANGUAGES = LANGUAGE_TOKENS.keys.freeze

    class Error < StandardError; end

    # Raised when a project requires a runtime outside the supported matrix
    # and the resolver is in strict mode. Lists the offending languages so the
    # caller can surface a clear failure instead of silently running in the
    # wrong image.
    class UnsupportedRuntimeError < Error
      attr_reader :languages

      def initialize(languages)
        @languages = Array(languages)
        super("Unsupported runtime(s) with no agent image: #{@languages.join(", ")}")
      end
    end

    attr_reader :project, :strict, :unsupported_languages

    def initialize(project, strict: false)
      @project = project
      @strict = strict
      @unsupported_languages = []
    end

    def self.resolve(project, **opts)
      new(project, **opts).resolve
    end

    # Convenience for callers that always want the base image (knowledge
    # collection, chat). Centralizes the tag so it is defined in one place.
    def self.base_image
      BASE_IMAGE
    end

    # @return [String] the resolved Docker image reference
    # @spec POLYGLOT-TEST-004
    # @spec POLYGLOT-TEST-006
    def resolve
      tokens = mapped_tokens
      raise UnsupportedRuntimeError, unsupported_languages if strict && unsupported_languages.any?

      return BASE_IMAGE if tokens.empty?
      return BASE_IMAGE if (tokens - BASE_LANGUAGES).empty?

      tag_for(tokens)
    end

    private

    def mapped_tokens
      @mapped_tokens ||= detected_languages.filter_map do |language|
        LANGUAGE_TOKENS[language] || track_unsupported(language)
      end.uniq.sort
    end

    def track_unsupported(language)
      @unsupported_languages << language
      nil
    end

    # Reads the project's detected language set, mirroring the precedence used
    # by +Prompts::LanguageCommands+: the persisted +language_profile+ test
    # languages take priority, then the broader +languages+ list, then the
    # single detected primary language as a final fallback.
    def detected_languages
      @detected_languages ||= begin
        langs = profile_languages.presence || primary_language_array
        langs.map { |language| language.to_s.strip.downcase }.reject(&:blank?).uniq
      end
    end

    def profile_languages
      profile = project.language_profile if project.respond_to?(:language_profile)
      return [] unless profile.is_a?(Hash)

      Array(profile["test_languages"].presence || profile["languages"])
    end

    def primary_language_array
      return [] unless project.respond_to?(:detected_language)

      Array(project.detected_language)
    end

    def tag_for(tokens)
      "#{IMAGE_PREFIX}:#{tokens.sort.uniq.join("-")}"
    end
  end
end
