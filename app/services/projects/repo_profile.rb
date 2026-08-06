# frozen_string_literal: true

module Projects
  class RepoProfile
    SUPPORTED_LANGUAGES = %w[
      ruby
      javascript
      typescript
      python
      go
      rust
      elixir
      swift
    ].freeze
    DEFAULT_TEST_LANGUAGES = %w[
      ruby
      javascript
      typescript
      python
      go
      rust
      elixir
      swift
    ].freeze

    class << self
      def normalize(profile, primary_language: nil, screenshot_framework: nil)
        stored = profile.is_a?(Hash) ? profile.deep_stringify_keys : {}
        languages = normalize_languages(stored["languages"])
        languages = fallback_languages(primary_language) if languages.empty?

        test_languages = normalize_languages(stored["test_languages"])
        test_languages = default_test_languages(languages) if test_languages.empty?

        framework = Projects::FrameworkProfile.normalize(stored["framework"]) ||
          Projects::FrameworkProfile.normalize(screenshot_framework)

        compact_hash(
          "languages" => languages,
          "test_languages" => test_languages,
          "framework" => framework,
          "confidence" => stored["confidence"],
          "detected_at" => stored["detected_at"],
          "source" => stored["source"],
          "manifest_path" => stored["manifest_path"],
          "marker_files" => normalize_strings(stored["marker_files"])
        )
      end

      def normalize_languages(values)
        Array(values)
          .filter_map { |value| normalize_language(value) }
          .uniq
      end

      def normalize_language(value)
        normalized = value.to_s.strip.downcase.presence
        return unless normalized

        SUPPORTED_LANGUAGES.include?(normalized) ? normalized : nil
      end

      def default_test_languages(languages)
        normalize_languages(languages).select { |language| DEFAULT_TEST_LANGUAGES.include?(language) }
      end

      private

      def fallback_languages(primary_language)
        language = normalize_language(primary_language)
        language ? [ language ] : []
      end

      def normalize_strings(values)
        Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      end

      def compact_hash(hash)
        hash.each_with_object({}) do |(key, value), result|
          next if value.respond_to?(:empty?) ? value.empty? : value.blank?

          result[key] = value
        end
      end
    end
  end
end
