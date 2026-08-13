# frozen_string_literal: true

require "digest"

module PromptAssembly
  # The output of a prompt assembly: prompt text plus provenance.
  #
  # +skipped+ records excluded or disabled sections as counts/provenance only —
  # never bodies — so untrusted content cannot leak through the result.
  #
  # @spec PROMPT-ASSEMBLY-010
  class Result
    attr_reader :text, :sections, :skipped, :profile_fingerprint, :budget_decisions

    def initialize(text:, sections:, skipped: [], profile_fingerprint: nil, budget_decisions: [])
      @text = text.to_s
      @sections = sections.freeze
      @skipped = skipped.freeze
      @profile_fingerprint = profile_fingerprint
      @budget_decisions = Array(budget_decisions).freeze
      @prompt_digest = Digest::SHA256.hexdigest(@text)
      freeze
    end

    # SHA-256 digest of the final prompt text. Stable for identical text
    # regardless of object identity.
    def prompt_digest
      @prompt_digest
    end

    # Count of trusted sections that reached the prompt.
    def included_count
      sections.size
    end

    # Count of sections excluded or disabled.
    def skipped_count
      skipped.size
    end
  end
end
