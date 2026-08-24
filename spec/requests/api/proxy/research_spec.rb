# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Proxy::Research" do # @spec EGRESS-POLICY-008 # @spec EGRESS-POLICY-009
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :running, project: project, external_metadata: external_metadata) }
  let(:external_metadata) { {} }
  let(:headers) do
    {
      "X-Agent-Run-Id" => agent_run.id.to_s,
      "X-Proxy-Token" => agent_run.proxy_token
    }
  end

  # The broker pins every outbound socket to the first public A record it
  # resolves so DNS rebinding cannot redirect the connection to a
  # private/internal host. These fixtures pin the well-known test
  # hostnames to representative public IPs.
  def public_host_ips
    {
      "docs.example.com" => "93.184.216.34",
      "duckduckgo.com" => "52.250.42.157"
    }.freeze
  end

  before do
    stub_resolver = instance_double(Resolv::DNS)
    allow(Resolv::DNS).to receive(:new).and_return(stub_resolver)
    allow(stub_resolver).to receive(:timeouts=)
    public_host_ips.each do |host, ip|
      allow(stub_resolver).to receive(:getresources)
        .with(host, Resolv::DNS::Resource::IN::A)
        .and_return([ Resolv::DNS::Resource::IN::A.new(ip) ])
      allow(stub_resolver).to receive(:getresources)
        .with(host, Resolv::DNS::Resource::IN::AAAA)
        .and_return([])
    end
  end

  def brokered_url(hostname, path, query: nil)
    base = "https://#{hostname}#{path}"
    query ? "#{base}?#{query}" : base
  end

  describe "GET /api/proxy/research/fetch" do
    let(:external_metadata) do
      {
        "egress_policy" => {
          "mode" => "proxy_restricted",
          "egress_profile" => "research",
          "destinations" => [],
          "required_destinations" => [],
          "resolved_at" => Time.current.iso8601
        }
      }
    end

    it "rejects locked runs whose egress policy does not enable research" do
      agent_run.update!(external_metadata: external_metadata.deep_merge(
        "egress_policy" => { "egress_profile" => "locked" }
      ))

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/guide" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.fetch("error")).to include("research")
    end

    it "rejects unsupported upstream methods" do
      get "/api/proxy/research/fetch",
        params: { url: "https://docs.example.com/guide", method: "post" },
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("GET/HEAD")
      expect(agent_run.reload.external_metadata.fetch("research_usage", {})).to eq({})
    end

    it "rejects invalid fetch URLs before consuming research usage" do
      get "/api/proxy/research/fetch",
        params: { url: "ftp://docs.example.com/guide" },
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("http or https")
      expect(agent_run.reload.external_metadata.fetch("research_usage", {})).to eq({})
    end

    it "enforces a per-run request budget" do
      stub_request(:get, brokered_url("docs.example.com", "/guide"))
        .to_return(status: 200, body: "Research document", headers: { "Content-Type" => "text/plain" })

      3.times do
        get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/guide" }, headers: headers
        expect(response).to have_http_status(:ok)
      end

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/guide" }, headers: headers

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.fetch("error")).to include("budget")
    end

    it "follows a bounded redirect chain and reports it in the response" do
      stub_request(:get, brokered_url("docs.example.com", "/start"))
        .to_return(status: 302, headers: { "Location" => "https://docs.example.com/final" })
      stub_request(:get, brokered_url("docs.example.com", "/final"))
        .to_return(status: 200, body: "<html><body>Final research page</body></html>",
          headers: { "Content-Type" => "text/html" })

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/start" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("url")).to eq("https://docs.example.com/final")
      expect(response.parsed_body.fetch("redirect_chain")).to eq(
        [
          { "status" => 302, "location" => "https://docs.example.com/final" }
        ]
      )
    end

    it "blocks secret-looking outbound requests before making any network call" do
      get "/api/proxy/research/fetch",
        params: { url: "https://docs.example.com/guide?token=#{agent_run.proxy_token}" },
        headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(WebMock).not_to have_requested(:any, /docs\.example\.com/)
      expect(EgressSecurityEvent.last).to have_attributes(
        agent_run: agent_run,
        event_kind: "redacted_secret_extraction",
        source_layer: "broker"
      )
      expect(EgressSecurityEvent.last.redacted_evidence).not_to include(agent_run.proxy_token)
    end

    it "blocks redirect hops whose target URL becomes secret-looking" do
      stub_request(:get, brokered_url("docs.example.com", "/start"))
        .to_return(status: 302, headers: { "Location" => "https://docs.example.com/final?token=#{agent_run.proxy_token}" })

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/start" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(WebMock).to have_requested(:get, brokered_url("docs.example.com", "/start"))
      expect(WebMock).not_to have_requested(:get, brokered_url("docs.example.com", "/final", query: "token=#{agent_run.proxy_token}"))
      expect(EgressSecurityEvent.last).to have_attributes(
        agent_run: agent_run,
        destination_host: "docs.example.com",
        event_kind: "redacted_secret_extraction"
      )
      expect(EgressSecurityEvent.last.redacted_evidence).not_to include(agent_run.proxy_token)
    end

    it "redacts credential-looking response content and returns quarantined evidence framing" do
      stub_request(:get, brokered_url("docs.example.com", "/leak"))
        .to_return(status: 200,
          body: "Use key sk_live_abcdefghijklmnopqrst only for testing.",
          headers: { "Content-Type" => "text/plain" })

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/leak" }, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.fetch("trust_level")).to eq("quarantined")
      expect(body.fetch("content")).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
      expect(body.fetch("content")).to include("[REDACTED:api_key]")
      expect(body.fetch("content")).not_to include("sk_live_abcdefghijklmnopqrst")
      expect(body.fetch("redacted")).to be(true)
    end

    it "persists research usage counters on the run and audits the request" do
      stub_request(:get, brokered_url("docs.example.com", "/guide"))
        .to_return(status: 200, body: "Research document", headers: { "Content-Type" => "text/plain" })

      expect {
        get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/guide" }, headers: headers
      }.to change { ExecutionAuditEvent.by_event_name("execution.research_fetch_completed").count }.by(1)

      usage = agent_run.reload.external_metadata.fetch("research_usage")
      expect(usage.fetch("requests_used")).to eq(1)
      expect(usage.fetch("bytes_used")).to be > 0
      expect(usage.fetch("tokens_used")).to be > 0
    end

    it "rejects upstream non-2xx fetch responses instead of returning them as successful research" do
      stub_request(:get, brokered_url("docs.example.com", "/guide"))
        .to_return(status: 500, body: "upstream failed", headers: { "Content-Type" => "text/plain" })

      get "/api/proxy/research/fetch", params: { url: "https://docs.example.com/guide" }, headers: headers

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body.fetch("error")).to include("status 500")
    end
  end

  describe "GET /api/proxy/research/search" do
    let(:external_metadata) do
      {
        "egress_policy" => {
          "mode" => "proxy_restricted",
          "egress_profile" => "research",
          "destinations" => [],
          "required_destinations" => [],
          "resolved_at" => Time.current.iso8601
        }
      }
    end

    it "returns quarantined search results from the brokered provider" do
      stub_request(:get, brokered_url("duckduckgo.com", "/html/", query: "q=integration+guide"))
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a class="result__a" href="https://docs.example.com/guide">Guide</a>
            <a class="result__snippet">Read the integration guide</a>
          </body></html>
        HTML

      get "/api/proxy/research/search", params: { q: "integration guide" }, headers: headers

      expect(response).to have_http_status(:ok)
      result = response.parsed_body.fetch("results").first
      expect(result.fetch("title")).to eq("Guide")
      expect(result.fetch("url")).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
      expect(result.fetch("url")).to include("https://docs.example.com/guide")
      expect(result.fetch("snippet")).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
    end

    it "charges search usage against the full returned payload" do
      stub_request(:get, brokered_url("duckduckgo.com", "/html/", query: "q=tiny"))
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a class="result__a" href="https://docs.example.com/guide">Guide</a>
            <a class="result__snippet">tiny</a>
          </body></html>
        HTML

      get "/api/proxy/research/search", params: { q: "tiny" }, headers: headers

      expect(response).to have_http_status(:ok)
      usage = agent_run.reload.external_metadata.fetch("research_usage")
      expect(usage.fetch("bytes_used")).to eq(response.body.bytesize)
      expect(usage.fetch("tokens_used")).to eq((response.body.length / 4.0).ceil)
    end

    it "rejects oversized titles and urls once the response budget is exhausted" do
      large_title = "Guide " + ("A" * 256)
      large_url = "https://docs.example.com/" + ("deep-path/" * 32)
      agent_run.update!(external_metadata: external_metadata.deep_merge(
        "research_usage" => {
          "requests_used" => 0,
          "bytes_used" => 0,
          "tokens_used" => AgentRuns::Research::BudgetLedger::TOKEN_LIMIT - 5
        }
      ))

      stub_request(:get, brokered_url("duckduckgo.com", "/html/", query: "q=tiny"))
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a class="result__a" href="#{large_url}">#{large_title}</a>
            <a class="result__snippet">tiny</a>
          </body></html>
        HTML

      get "/api/proxy/research/search", params: { q: "tiny" }, headers: headers

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.fetch("error")).to include("budget")
    end

    it "rejects upstream non-2xx search responses instead of returning an empty result set" do
      stub_request(:get, brokered_url("duckduckgo.com", "/html/", query: "q=integration+guide"))
        .to_return(status: 500, body: "<html><body>upstream failed</body></html>",
          headers: { "Content-Type" => "text/html" })

      get "/api/proxy/research/search", params: { q: "integration guide" }, headers: headers

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body.fetch("error")).to include("status 500")
    end
  end
end
