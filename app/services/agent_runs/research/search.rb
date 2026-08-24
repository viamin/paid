# frozen_string_literal: true

module AgentRuns
  module Research
    class Search
      SearchResult = Data.define(:payload)

      PROVIDER_URL = "https://duckduckgo.com/html/".freeze
      MAX_RESULTS = 5

      def self.call(...)
        new(...).call
      end

      def initialize(agent_run:, query:)
        @agent_run = agent_run
        @query = query.to_s
      end

      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def call
        guard_outbound_secret!
        BudgetLedger.reserve_request!(agent_run: agent_run)

        response = HttpClient.fetch(
          url: provider_uri.to_s,
          method: "GET",
          before_request: ->(request_uri) { guard_redirect_secret!(request_uri) }
        )
        result_set = extract_results(response.body)
        results = result_set.map(&:payload)
        payload = { "results" => results }
        serialized_payload = JSON.generate(payload)
        usage = BudgetLedger.consume_response!(
          agent_run: agent_run,
          bytes: serialized_payload.bytesize,
          tokens: estimate_tokens(serialized_payload)
        )

        audit!(
          event_name: "execution.research_search_completed",
          metadata: {
            "query" => SecretGuard.redact_text(query),
            "provider_url" => SecretGuard.redact_text(response.uri.to_s),
            "result_count" => results.length,
            "policy_result" => "allowed",
            "requests_used" => usage["requests_used"],
            "bytes_used" => usage["bytes_used"],
            "tokens_used" => usage["tokens_used"]
          }
        )

        payload
      end

      private

      attr_reader :agent_run, :query

      def provider_uri
        uri = URI.parse(PROVIDER_URL)
        uri.query = URI.encode_www_form(q: query)
        uri
      end

      def extract_results(html)
        document = Nokogiri::HTML(html.to_s)
        anchors = document.css("a.result__a")

        anchors.first(MAX_RESULTS).map do |anchor|
          snippet_node = anchor.xpath("following::a[@class='result__snippet'][1]").first ||
            anchor.xpath("following::div[@class='result__snippet'][1]").first
          snippet_text = snippet_node&.text.to_s.squish
          sanitized_snippet = ResponseSanitizer.call(body: snippet_text, content_type: "text/plain")
          sanitized_url = ResponseSanitizer.call(body: anchor["href"].to_s, content_type: "text/plain")

          SearchResult.new(
            payload: {
              "title" => SecretGuard.redact_text(anchor.text.to_s.squish),
              "url" => sanitized_url.content,
              "snippet" => sanitized_snippet.content
            }
          )
        end
      end

      def guard_outbound_secret!
        result = SecretGuard.inspect!(
          agent_run: agent_run,
          text: query,
          destination_host: URI.parse(PROVIDER_URL).host
        )
        return unless result.blocked?

        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          event_kind: "redacted_secret_extraction",
          severity: "critical",
          source_layer: "broker",
          destination_host: URI.parse(PROVIDER_URL).host,
          matched_rule: result.rule,
          redacted_evidence: result.redacted_evidence,
          occurred_at: Time.current
        )
        audit!(
          event_name: "execution.research_search_blocked",
          metadata: {
            "query" => SecretGuard.redact_text(query),
            "policy_result" => "blocked_secret",
            "matched_rule" => result.rule
          }
        )
        raise RequestInvalidError, "Brokered research blocked a secret-looking query"
      end

      def guard_redirect_secret!(request_uri)
        result = SecretGuard.inspect!(
          agent_run: agent_run,
          text: request_uri.to_s,
          destination_host: request_uri.host
        )
        return unless result.blocked?

        EgressSecurityEvent.create!(
          account: agent_run.project.account,
          project: agent_run.project,
          agent_run: agent_run,
          event_kind: "redacted_secret_extraction",
          severity: "critical",
          source_layer: "broker",
          destination_host: request_uri.host,
          matched_rule: result.rule,
          redacted_evidence: result.redacted_evidence,
          occurred_at: Time.current
        )
        audit!(
          event_name: "execution.research_search_blocked",
          metadata: {
            "query" => SecretGuard.redact_text(query),
            "provider_url" => SecretGuard.redact_text(request_uri.to_s),
            "policy_result" => "blocked_secret",
            "matched_rule" => result.rule
          }
        )
        raise RequestInvalidError, "Brokered research blocked a secret-looking request"
      end

      def audit!(event_name:, metadata:)
        ExecutionAuditEvents::Lifecycle.record(
          event_name: event_name,
          actor_id: "agent_runs.research.search",
          agent_run: agent_run,
          networking_policy: agent_run.egress_policy_snapshot || {},
          metadata: metadata
        )
      end

      def estimate_tokens(text)
        [ (text.to_s.length / 4.0).ceil, 0 ].max
      end
    end
  end
end
