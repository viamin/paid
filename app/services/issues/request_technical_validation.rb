# frozen_string_literal: true

module Issues
  # Prepares one bounded continuation in an isolated AgentRun. This is an
  # operator action, not host-shell access or a flag/allowlist bypass.
  # @spec PARTIAL-CLOSEOUT-030
  class RequestTechnicalValidation
    Result = Data.define(:continuation, :code, :message, :readiness) do
      def success? = continuation&.success?
      def agent_run = continuation&.agent_run
    end

    def self.call(...) = new(...).call

    def initialize(issue:, actor:, tool_entry_id: nil)
      @issue = issue
      @actor = actor
      @tool_entry_id = tool_entry_id.presence
    end

    def call
      readiness = TechnicalValidationReadiness.call(project: issue.project, tool_entry_id:)
      return Result.new(continuation: nil, code: readiness.code, message: readiness.message, readiness:) unless readiness.ready?

      continuation = RequestContinuation.call(
        issue:, actor:, reason: "Bounded technical prerequisite validation requested from Inbox.",
        continuation_mode: "technical_validation", custom_prompt: prompt,
        marketplace_entry_ids: readiness.tool_entry ? [ readiness.tool_entry.id ] : nil,
        validation_metadata: readiness.evidence.merge("status" => "queued")
      )
      Result.new(continuation:, code: continuation.code, message: continuation.message, readiness:)
    end

    private

    attr_reader :issue, :actor, :tool_entry_id

    def prompt
      <<~PROMPT
        Perform only the requested technical prerequisite validation in this isolated checkout. Use the selected native analyzer#{tool_entry_id ? " and the attached allowlisted tool sidecar" : ""}. Do not run code on the control plane, request host shell access, or mount host sockets. Record command stdout, stderr, exit status, pinned checkout/image/tool identity, endpoint response, and cleanup result in the run evidence. If unavailable, failed, cancelled, or partial, report that exact outcome; do not claim completion.
      PROMPT
    end
  end
end
