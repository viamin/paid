# frozen_string_literal: true

require "digest"

module PromptAssembly
  # The output of a prompt assembly: prompt text plus provenance.
  #
  # +skipped+ records excluded or disabled sections as counts/provenance only —
  # never bodies — so untrusted content cannot leak through the result.
  #
  # @spec PROMPT-ASSEMBLY-004
  class Result
    attr_reader :text, :sections, :skipped

    def initialize(text:, sections:, skipped: [])
      @text = text.to_s
      @sections = sections.freeze
      @skipped = skipped.freeze
      @digest = Digest::SHA256.hexdigest(fingerprint_source)
      freeze
    end

    # Stable SHA-256 digest over the assembled section keys and content, for
    # configuration-bundle and run provenance fingerprinting. Two assemblies
    # that reached the agent with identical sections produce the same digest.
    def digest
      @digest
    end

    # Section-level provenance: which sections reached the prompt (key, source,
    # trust level, required/safety flag, inclusion reason), the digest, and the
    # skipped sections. Section *bodies* are intentionally excluded so this is
    # safe to persist alongside configuration bundles and run metadata.
    def provenance
      {
        digest: digest,
        section_count: sections.size,
        sections: sections.map { |section| section_provenance(section) },
        skipped: skipped
      }
    end

    private

    def fingerprint_source
      sections.map { |section| "#{section.key}\n#{section.content}" }.join("\n---\n")
    end

    def section_provenance(section)
      {
        key: section.key,
        source: section.source,
        trust_level: section.trust_level,
        required: section.required?,
        inclusion_reason: section.inclusion_reason
      }.compact
    end
  end
end
