# frozen_string_literal: true

module AgentRuns
  module Research
    class Fetcher
      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:, url:, method:)
        @agent_run = agent_run
        @url = url
        @method = method.to_s.upcase.presence || "GET"
      end

      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def call
        uri = HttpClient.validate_request!(url: url, method: method)
        guard_outbound_secret!(url, uri.host)
        BudgetLedger.reserve_request!(agent_run: agent_run)

        response = HttpClient.fetch(url: url, method: method)
        sanitized = ResponseSanitizer.call(body: response.body, content_type: response.content_type)
        usage = BudgetLedger.consume_response!(
          agent_run: agent_run,
          bytes: sanitized.content.bytesize,
          tokens: sanitized.tokens_estimate
        )

        audit!(
          event_name: "execution.research_fetch_completed",
          metadata: {
            "url" => SecretGuard.redact_text(response.uri.to_s),
            "method" => method,
            "status" => response.status,
            "content_type" => response.content_type,
            "redirect_chain" => response.redirect_chain,
            "policy_result" => "allowed",
            "requests_used" => usage["requests_used"],
            "bytes_used" => usage["bytes_used"],
            "tokens_used" => usage["tokens_used"]
          }
        )

        {
          "url" => response.uri.to_s,
          "status" => response.status,
          "content_type" => response.content_type,
          "redirect_chain" => response.redirect_chain,
          "trust_level" => "quarantined",
          "content" => sanitized.content,
          "redacted" => sanitized.redacted,
          "quarantined" => sanitized.quarantined
        }
      end

      private

      attr_reader :agent_run, :url, :method

      def guard_outbound_secret!(text, destination_host)
        result = SecretGuard.inspect!(agent_run: agent_run, text: text, destination_host: destination_host)
        return unless result.blocked?

        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          event_kind: "redacted_secret_extraction",
          severity: "critical",
          source_layer: "broker",
          destination_host: destination_host,
          matched_rule: result.rule,
          redacted_evidence: result.redacted_evidence,
          occurred_at: Time.current
        )
        audit!(
          event_name: "execution.research_fetch_blocked",
          metadata: {
            "url" => SecretGuard.redact_text(text),
            "method" => method,
            "policy_result" => "blocked_secret",
            "matched_rule" => result.rule
          }
        )
        raise RequestInvalidError, "Brokered research blocked a secret-looking request"
      end

      def audit!(event_name:, metadata:)
        ExecutionAuditEvents::Lifecycle.record(
          event_name: event_name,
          actor_id: "agent_runs.research.fetcher",
          agent_run: agent_run,
          networking_policy: agent_run.egress_policy_snapshot || {},
          metadata: metadata
        )
      end
    end
  end
end
