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
        payload = { "trust_level" => "quarantined", "results" => results }
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

        # Result fields are returned as clean redacted strings so a caller can
        # round-trip +url+ directly into the fetch endpoint without having to
        # strip framing. The quarantine wrapping (untrusted-evidence notice)
        # is hoisted to the top-level payload via +trust_level+, matching the
        # shape the fetch endpoint already returns.
        anchors.first(MAX_RESULTS).map do |anchor|
          snippet_node = anchor.xpath("following::a[@class='result__snippet'][1]").first ||
            anchor.xpath("following::div[@class='result__snippet'][1]").first

          SearchResult.new(
            payload: {
              "title" => SecretGuard.redact_text(anchor.text.to_s.squish),
              "url" => SecretGuard.redact_text(anchor["href"].to_s),
              "snippet" => SecretGuard.redact_text(snippet_node&.text.to_s.squish.to_s)
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

        SecretGuard.block_and_record!(
          agent_run: agent_run,
          result: result,
          destination_host: URI.parse(PROVIDER_URL).host,
          audit_event: "execution.research_search_blocked",
          actor_id: "agent_runs.research.search",
          metadata: { "query" => SecretGuard.redact_text(query) }
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

        SecretGuard.block_and_record!(
          agent_run: agent_run,
          result: result,
          destination_host: request_uri.host,
          audit_event: "execution.research_search_blocked",
          actor_id: "agent_runs.research.search",
          metadata: {
            "query" => SecretGuard.redact_text(query),
            "provider_url" => SecretGuard.redact_text(request_uri.to_s)
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
