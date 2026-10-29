# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::FetchEvidenceArtifact do
  it "retrieves through the SSRF-safe transport and strips HTML markup" do # @spec PARTIAL-CLOSEOUT-035
    allow(AgentRuns::Research::HttpClient).to receive(:fetch).and_return(
      instance_double(AgentRuns::Research::HttpClient::Result,
        content_type: "text/html", body: "<script>attack()</script><p>Reviewed &amp; approved</p>")
    )

    result = described_class.call("https://evidence.example.test/report")

    expect(result).to eq("Reviewed & approved")
    expect(AgentRuns::Research::HttpClient).to have_received(:fetch).with(
      url: "https://evidence.example.test/report", method: "GET"
    )
  end

  it "bounds retrieved content before prompt assembly" do # @spec PARTIAL-CLOSEOUT-035
    allow(AgentRuns::Research::HttpClient).to receive(:fetch).and_return(
      instance_double(AgentRuns::Research::HttpClient::Result,
        content_type: "text/plain", body: "a" * (described_class::MAX_PROMPT_CHARS + 100))
    )

    expect(described_class.call("https://evidence.example.test/report").length)
      .to eq(described_class::MAX_PROMPT_CHARS)
  end

  it "rejects an empty artifact so a claim alone cannot become sufficient" do # @spec PARTIAL-CLOSEOUT-035
    allow(AgentRuns::Research::HttpClient).to receive(:fetch).and_return(
      instance_double(AgentRuns::Research::HttpClient::Result, content_type: "text/plain", body: "  ")
    )

    expect { described_class.call("https://evidence.example.test/report") }
      .to raise_error(AgentRuns::Research::RequestInvalidError, /blank/)
  end
end
