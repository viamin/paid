# frozen_string_literal: true

module PromptAssembly
  # Records a section (or a class of content) that was not included in the
  # assembled prompt and why. +count+ is optional: for content exclusions such
  # as non-allowlisted comments, the assembler records only the number of items
  # excluded, never their text.
  class SkippedSection
    attr_reader :key, :reason, :count

    def initialize(key:, reason:, count: nil)
      @key = key
      @reason = reason
      @count = count
    end

    def to_h
      { key: key, reason: reason }.tap { |hash| hash[:count] = count unless count.nil? }
    end
  end
end
