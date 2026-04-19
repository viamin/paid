# frozen_string_literal: true

class ConventionalCommitTitle
  CONVENTIONAL_PATTERN = /\A(?<type>feat|fix|perf|docs|refactor|ci|build|test|chore)(?<rest>(?:\([^)]+\))?!?: .+)\z/i

  class << self
    def normalize(title)
      match = title.to_s.strip.match(CONVENTIONAL_PATTERN)
      return nil unless match

      "#{match[:type].downcase}#{match[:rest]}"
    end
  end
end
