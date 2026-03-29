# frozen_string_literal: true

module Knowledge
  module Redaction
    class Scanner
      Match = Data.define(:pattern, :offset, :length)

      PATTERNS = {
        api_key: /(?:api[_-]?key|apikey)\s*[:=]\s*["']?([a-zA-Z0-9_\-]{20,})["']?/i,
        aws_key: /(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}/,
        github_token: /gh[ps]_[a-zA-Z0-9]{36,}/,
        jwt: /eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/,
        password: /(?:password|passwd|secret)\s*[:=]\s*["']([^"']+)["']/i,
        email: /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
        connection_string: /(?:postgres|mysql|redis|mongodb):\/\/[^\s"']+/i,
        private_key: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/
      }.freeze

      def self.scan(text)
        new.scan(text)
      end

      def scan(text)
        return [] if text.nil? || text.empty?

        matches = []
        PATTERNS.each do |name, regex|
          text.scan(regex) do
            md = Regexp.last_match
            matches << Match.new(pattern: name, offset: md.begin(0), length: md[0].length)
          end
        end

        matches.sort_by(&:offset)
      end
    end
  end
end
