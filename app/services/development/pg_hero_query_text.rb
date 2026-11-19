# frozen_string_literal: true

module Development
  module PgHeroQueryText
    TOKEN_REPLACEMENTS = {
      SCONST: "'[filtered]'", USCONST: "'[filtered]'", BCONST: "B'0'", XCONST: "X'0'",
      ICONST: "0", FCONST: "0", SQL_COMMENT: " ", C_COMMENT: " "
    }.freeze

    # @spec RAILS-CONTROL-PLANE-020
    def self.call(query)
      normalized = PgQuery.normalize(query)
      tokens = PgQuery.scan(normalized).first.tokens
      filtered = normalized.b
      tokens.reverse_each do |token|
        replacement = TOKEN_REPLACEMENTS[token.token]
        filtered[token.start...token.end] = replacement if replacement
      end
      filtered.force_encoding(Encoding::UTF_8).strip
    rescue PgQuery::ParseError, PgQuery::ScanError
      "<unable to filter data>"
    end
  end
end
