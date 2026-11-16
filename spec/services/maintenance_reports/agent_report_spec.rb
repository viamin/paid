# frozen_string_literal: true

require "rails_helper"

RSpec.describe MaintenanceReports::AgentReport do
  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-025
  it "parses the marker-delimited persistence fields" do
    payload = {
      resolved_scope: "app/services", exclusions: [], completed_checks: [ { name: "debride" } ],
      incomplete_checks: [], evidence: { revision: "abc123" },
      findings: [ { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
        locations: [ { path: "app/legacy.rb", line: 4 } ], verification_disposition: "unverified" } ]
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

  it "rejects invalid finding classifications before persistence" do
    payload = {
      exclusions: [], completed_checks: [], incomplete_checks: [], evidence: {},
      findings: [ { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
        locations: [], agent_assessment: "certain", verification_disposition: "maybe" } ]
    }
    output = "<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->"

    expect { described_class.parse(output) }.to raise_error(described_class::InvalidReport, /disposition/)
  end

  # @spec MAINT-022 MAINT-025
  it "rejects finding values that exceed persistence bounds" do
    finding = { category: "unused_code", claim: "Legacy has no callers", symbols: [ "Legacy" ],
      locations: [], raw_tool_confidence: 1.01, verification_disposition: "unverified" }

    expect { parse(finding:) }.to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(raw_tool_confidence: -0.01)) }
      .to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(raw_tool_confidence: "0.85")) }
      .to raise_error(described_class::InvalidReport, /between 0 and 1/)
    expect { parse(finding: finding.merge(category: "x" * 101, raw_tool_confidence: 0.85)) }
      .to raise_error(described_class::InvalidReport, /at most 100 characters/)
  end

  def parse(finding:)
    payload = { exclusions: [], completed_checks: [], incomplete_checks: [], evidence: {}, findings: [ finding ] }
    described_class.parse("<!-- maintenance-report-start -->\n#{JSON.generate(payload)}\n<!-- maintenance-report-end -->")
  end
end
