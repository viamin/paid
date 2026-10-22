# frozen_string_literal: true

module AgentRuns
  # Redacts and bounds application-log content before it crosses a persistence or API boundary.
  # @spec APP-DIAGNOSTICS-001
  # @spec APP-DIAGNOSTICS-004
  class ApplicationLog
    MAX_BYTES = 32 * 1024

    Bounded = Data.define(:content, :truncated)

    def self.redact_and_bound(content, agent_run: nil)
      redacted = redact(content, agent_run:)
      bounded = truncate(redacted)

      Bounded.new(content: bounded, truncated: bounded.bytesize < redacted.bytesize)
    end

    def self.redact(content, agent_run:)
      normalized = content.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      AgentRuns::Research::SecretGuard.redact_text(normalized, agent_run:)
    end
    private_class_method :redact

    def self.truncate(content)
      return content if content.bytesize <= MAX_BYTES

      content.byteslice(0, MAX_BYTES).force_encoding(Encoding::UTF_8).scrub("")
    end
    private_class_method :truncate
  end
end
