# frozen_string_literal: true

module StyleGuides
  # Detects the programming language of a style guide based on its content.
  # Scores each language by how many of its indicator keywords appear in the content.
  #
  # @example
  #   language = StyleGuides::DetectLanguage.call(content: raw_text)
  #   # => "ruby"
  class DetectLanguage
    LANGUAGE_INDICATORS = {
      "ruby" => %w[
        def end class module require frozen_string_literal
        attr_reader attr_writer attr_accessor rubocop
        rails rspec bundle gem rake
      ],
      "javascript" => %w[
        const let var function => import export
        require module.exports eslint prettier
        npm yarn node react vue angular
      ],
      "typescript" => %w[
        interface type enum implements extends
        readonly abstract declare namespace
        tslint tsconfig angular
      ],
      "python" => %w[
        def class import from self __init__
        pylint flake8 mypy pytest pip
        django flask fastapi
      ],
      "go" => %w[
        func package import struct interface
        goroutine chan defer go fmt
        golangci golint
      ],
      "rust" => %w[
        fn let mut struct impl trait enum
        use mod pub crate cargo clippy
        unsafe async await
      ]
    }.freeze

    attr_reader :content

    def initialize(content:)
      @content = content.to_s.downcase
    end

    def self.call(...)
      new(...).call
    end

    def call
      scores = LANGUAGE_INDICATORS.transform_values do |indicators|
        indicators.count { |word| match_indicator?(word) }
      end

      best = scores.max_by { |_lang, score| score }
      return nil if best.nil? || best.last.zero?

      best.first
    end

    private

    def match_indicator?(word)
      if word.match?(/\A\w+\z/)
        content.match?(/\b#{Regexp.escape(word)}\b/)
      else
        content.include?(word)
      end
    end
  end
end
