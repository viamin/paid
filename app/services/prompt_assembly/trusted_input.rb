# frozen_string_literal: true

module PromptAssembly
  # A single prompt input classified by trust.
  #
  # @spec PROMPT-ASSEMBLY-001, PROMPT-ASSEMBLY-004
  #
  # Trust levels:
  # - :trusted     — instructions the agent may follow (allowlisted humans,
  #                  Paid-generated markers, tenant-authored configuration).
  # - :quarantined — evidence the agent may read but MUST NOT follow
  #                  (repository code/docs, knowledge-base content).
  # - :excluded    — content that must never reach the prompt (untrusted
  #                  authors, unrecognized bot content).
  class TrustedInput
    KINDS = %i[
      issue pull_request comment review repository knowledge marketplace tenant
    ].freeze
    TRUST_LEVELS = %i[trusted quarantined excluded].freeze

    attr_reader :kind, :source, :login, :body, :trust, :exclusion_reason

    def initialize(kind:, source:, body:, trust:, login: nil, exclusion_reason: nil)
      @kind = normalize_kind(kind)
      @source = source.to_sym
      @login = login
      @body = body
      @trust = normalize_trust(trust)
      @exclusion_reason = exclusion_reason
      freeze
    end

    def trusted?
      trust == :trusted
    end

    def quarantined?
      trust == :quarantined
    end

    def excluded?
      trust == :excluded
    end

    def included?
      !excluded?
    end

    # Counts/provenance only — never the body — for excluded content.
    def provenance
      return nil unless excluded?

      {
        kind: kind,
        source: source,
        login: login,
        reason: exclusion_reason || "excluded"
      }.compact
    end

    # Convert to a renderable Section. Excluded inputs become excluded
    # sections so the assembler records them as provenance, never text.
    def to_section(key: nil, required: false, inclusion_reason: nil)
      Section.new(
        key: key || source,
        source: source,
        content: body.to_s,
        trust_level: trust,
        required: required,
        inclusion_reason: inclusion_reason,
        exclusion_reason: exclusion_reason
      )
    end

    private

    def normalize_kind(kind)
      normalized = kind.to_sym
      raise ArgumentError, "unknown kind #{kind.inspect}" unless KINDS.include?(normalized)

      normalized
    end

    def normalize_trust(trust)
      normalized = trust.to_sym
      raise ArgumentError, "unknown trust level #{trust.inspect}" unless TRUST_LEVELS.include?(normalized)

      normalized
    end
  end
end
