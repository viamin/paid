# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReports::AgentReport do
  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  it "parses the marker-delimited persistence fields" do
    payload = {
      resolved_scope: "app/services", exclusions: [], completed_checks: [ { name: "debride" } ],
      incomplete_checks: [], evidence: { revision: "abc123" },
      findings: [ { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
        locations: [ { path: "app/legacy.rb", line: 4 } ], evidence_source: "agent", analyzer_provenance: {},
        verification_disposition: "unverified" } ]
    }
    output = "Summary\n<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->"

    report = described_class.parse(output)

    expect(report).to include(resolved_scope: "app/services", evidence: { "revision" => "abc123" })
    expect(report.fetch(:findings).sole).to include(category: "unused_code", symbols: [ "Legacy" ])
  end

  it "rejects missing and structurally invalid reports" do
    expect { described_class.parse("plain prose") }.to raise_error(described_class::InvalidReport, /missing/)
    invalid = "<!-- maintenance-report-start -->\n{\"findings\": []}\n<!-- maintenance-report-end -->"
    expect { described_class.parse(invalid) }.to raise_error(described_class::InvalidReport, /exclusions/)
  end

  # @spec MAINT-020 MAINT-022
  it "uses the final report block when earlier output contains marker-shaped content" do
    template = { exclusions: [], completed_checks: [], incomplete_checks: [], evidence: {}, findings: [] }
    final = template.merge(completed_checks: [ { "name" => "debride" } ],
      findings: [ { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
        locations: [], evidence_source: "agent", analyzer_provenance: {}, verification_disposition: "unverified" } ])
    output = [ report_block(template), report_block(final) ].join("\n")

    report = described_class.parse(output)

    expect(report.fetch(:completed_checks)).to eq([ { "name" => "debride" } ])
    expect(report.fetch(:findings).sole).to include(claim: "Legacy has no callers")
  end

  it "rejects invalid finding classifications before persistence" do
    payload = {
      exclusions: [], completed_checks: [], incomplete_checks: [], evidence: {},
      findings: [ { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
        locations: [], evidence_source: "agent", analyzer_provenance: {}, agent_assessment: "certain", verification_disposition: "maybe" } ]
    }
    output = "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->"

    expect { described_class.parse(output) }.to raise_error(described_class::InvalidReport, /disposition/)
  end

  # @spec MAINT-022 MAINT-025
  it "rejects finding values that exceed persistence bounds" do
    finding = { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
      locations: [], evidence_source: "agent", analyzer_provenance: {}, raw_tool_confidence: 1.01,
      verification_disposition: "unverified" }

    expect { parse(finding:) }.to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(raw_tool_confidence: -0.01)) }
      .to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(raw_tool_confidence: "0.85")) }
      .to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(category: "x" * 101, raw_tool_confidence: 0.85)) }
      .to raise_error(described_class::InvalidReport, /at most 100 characters/)
    expect { parse(finding: finding.merge(claim: { text: "Legacy has no callers" }, raw_tool_confidence: 0.85)) }
      .to raise_error(described_class::InvalidReport, /claim must be a string/)
  end

  # @spec MAINT-043
  it "rejects a finding that omits analyzer provenance" do
    finding = { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
      locations: [], evidence_source: "agent", verification_disposition: "unverified" }

    expect { parse(finding:) }.to raise_error(described_class::InvalidReport, /analyzer_provenance/)
  end

  # @spec MAINT-043
  it "requires complete provenance when a finding explicitly uses tool evidence" do
    finding = { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
      locations: [], evidence_source: "tool", analyzer_provenance: {}, raw_tool_confidence: nil,
      verification_disposition: "unverified" }

    expect { parse(finding:) }.to raise_error(described_class::InvalidReport, /must not be empty/)
    expect { parse(finding: finding.merge(analyzer_provenance: { "name" => "debride" })) }
      .to raise_error(described_class::InvalidReport, /version, configuration/)
  end

  # @spec MAINT-043
  it "rejects an unknown finding evidence source" do
    finding = { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
      locations: [], evidence_source: "guess", analyzer_provenance: {}, verification_disposition: "unverified" }

    expect { parse(finding:) }.to raise_error(described_class::InvalidReport, /evidence source/)
  end

  def parse(finding:)
    payload = { exclusions: [], completed_checks: [], incomplete_checks: [], evidence: {}, findings: [ finding ] }
    described_class.parse(report_block(payload))
  end

  # @spec MAINT-022
  it "rejects a truncated final report instead of using an earlier clean block" do
    payload = { exclusions: [], completed_checks: [ { name: "callers" } ], incomplete_checks: [], evidence: {}, findings: [] }
    output = report_block(payload) + "\n<!-- maintenance-report-start -->\n{\"findings\":"

    expect { described_class.parse(output) }.to raise_error(described_class::InvalidReport, /truncated/)
  end

  def report_block(payload)
    "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->"
  end
end
