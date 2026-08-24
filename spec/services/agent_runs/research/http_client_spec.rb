# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Research::HttpClient do # @spec EGRESS-POLICY-008 # @spec EGRESS-POLICY-009
  let(:dns_resolver) { instance_double(Resolv::DNS) }
  let(:client) { described_class.new(dns_resolver: dns_resolver) }

  before do
    allow(dns_resolver).to receive(:timeouts=)
  end

  describe "#fetch" do
    let(:public_ip) { "93.184.216.34" }

    def stub_a_record(host, addresses)
      addresses = Array(addresses).map(&:to_s)
      a_records = addresses.select { |ip| ip.include?(".") }.map { |ip| Resolv::DNS::Resource::IN::A.new(ip) }
      aaaa_records = addresses.reject { |ip| ip.include?(".") }.map { |ip| Resolv::DNS::Resource::IN::AAAA.new(ip) }
      allow(dns_resolver).to receive(:getresources).with(host, Resolv::DNS::Resource::IN::A).and_return(a_records)
      allow(dns_resolver).to receive(:getresources).with(host, Resolv::DNS::Resource::IN::AAAA).and_return(aaaa_records)
    end

    it "pins the connection to a public A record and forwards the original Host header" do
      stub_a_record("docs.iana.org", public_ip)

      stub_request(:get, "https://#{public_ip}/guide")
        .with(headers: { "Host" => "docs.iana.org", "User-Agent" => "PaidResearchBroker/1.0" })
        .to_return(status: 200, body: "Hello", headers: { "Content-Type" => "text/plain" })

      result = client.fetch(url: "https://docs.iana.org/guide", method: "GET")

      expect(result.uri.to_s).to eq("https://docs.iana.org/guide")
      expect(result.body).to eq("Hello")
    end

    it "blocks hosts that resolve to a loopback address (SSRF guard)" do
      stub_a_record("attacker.com", "127.0.0.1")

      expect {
        client.fetch(url: "https://attacker.com/admin", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
      expect(WebMock).not_to have_requested(:any, /attacker\.com/)
    end

    it "blocks hosts that resolve to an IPv4 link-local address" do
      stub_a_record("attacker.com", "169.254.169.254")

      expect {
        client.fetch(url: "https://attacker.com/latest/meta-data/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
      expect(WebMock).not_to have_requested(:any, /attacker\.com/)
    end

    it "blocks hosts that resolve to an RFC1918 private address" do
      stub_a_record("attacker.com", "10.0.0.5")

      expect {
        client.fetch(url: "https://attacker.com/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
    end

    it "blocks hosts whose A records are mixed public and private" do
      a_records = [
        Resolv::DNS::Resource::IN::A.new(public_ip),
        Resolv::DNS::Resource::IN::A.new("10.0.0.5")
      ]
      allow(dns_resolver).to receive(:getresources).with("attacker.com", Resolv::DNS::Resource::IN::A).and_return(a_records)
      allow(dns_resolver).to receive(:getresources).with("attacker.com", Resolv::DNS::Resource::IN::AAAA).and_return([])

      expect {
        client.fetch(url: "https://attacker.com/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
    end

    it "blocks direct IP-literal hosts through the host-pattern shape check" do
      expect {
        client.fetch(url: "https://10.0.0.5/internal", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /IP literal/)
      expect(WebMock).not_to have_requested(:any, /10\.0\.0\.5/)
    end

    it "blocks IPv6 unique-local and link-local addresses" do
      stub_a_record("attacker.com", "fc00::1")

      expect {
        client.fetch(url: "https://attacker.com/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
    end

    it "fails closed when DNS resolution returns no addresses" do
      allow(dns_resolver).to receive(:getresources).and_return([])

      expect {
        client.fetch(url: "https://nx.iana.org/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /could not be resolved/)
    end

    it "fails closed when the resolver raises ResolvError" do
      allow(dns_resolver).to receive(:getresources).and_raise(Resolv::ResolvError, "DNS failure")

      expect {
        client.fetch(url: "https://broken.iana.org/", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /could not be resolved/)
    end

    it "re-resolves and re-validates every redirect hop" do
      stub_a_record("docs.iana.org", public_ip)
      allow(dns_resolver).to receive(:getresources).with("evil.com", Resolv::DNS::Resource::IN::A)
        .and_return([ Resolv::DNS::Resource::IN::A.new("127.0.0.1") ])
      allow(dns_resolver).to receive(:getresources).with("evil.com", Resolv::DNS::Resource::IN::AAAA)
        .and_return([])

      stub_request(:get, "https://#{public_ip}/start")
        .to_return(status: 302, headers: { "Location" => "https://evil.com/landing" })

      expect {
        client.fetch(url: "https://docs.iana.org/start", method: "GET")
      }.to raise_error(AgentRuns::Research::RequestInvalidError, /non-public/)
    end
  end

  describe ".public_address?" do
    let(:public_check) { ->(ip) { client.send(:public_address?, ip) } }

    it "accepts public IPv4 addresses" do
      expect(public_check.call("8.8.8.8")).to be(true)
      expect(public_check.call("93.184.216.34")).to be(true)
    end

    it "rejects IPv4 loopback, link-local, and RFC1918 addresses" do
      expect(public_check.call("127.0.0.1")).to be(false)
      expect(public_check.call("169.254.169.254")).to be(false)
      expect(public_check.call("10.0.0.1")).to be(false)
      expect(public_check.call("172.16.0.1")).to be(false)
      expect(public_check.call("192.168.1.1")).to be(false)
    end

    it "rejects other IPv4 special-use ranges that are not publicly routable" do
      expect(public_check.call("0.0.0.0")).to be(false)
      expect(public_check.call("100.64.0.1")).to be(false)
      expect(public_check.call("198.18.0.1")).to be(false)
      expect(public_check.call("224.0.0.1")).to be(false)
      expect(public_check.call("240.0.0.1")).to be(false)
    end

    it "rejects IPv6 loopback, link-local, unique-local, and AWS metadata endpoints" do
      expect(public_check.call("::")).to be(false)
      expect(public_check.call("::1")).to be(false)
      expect(public_check.call("fe80::1")).to be(false)
      expect(public_check.call("fc00::1")).to be(false)
      expect(public_check.call("fd00:ec2::254")).to be(false)
    end

    it "accepts public IPv6 addresses" do
      expect(public_check.call("2606:4700:4700::1111")).to be(true)
    end

    it "returns false for unparseable addresses" do
      expect(public_check.call("not-an-ip")).to be(false)
    end
  end
end
