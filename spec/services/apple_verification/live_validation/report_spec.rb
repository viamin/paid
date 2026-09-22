# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-LIVE-007
RSpec.describe AppleVerification::LiveValidation::Report do
  subject(:markdown) { described_class.new(result: result, archive_path: "docs/rdrs/live-validation-2026-09-22-rdr-068.md").render }

  let(:started_at) { Time.zone.now }
  let(:result) do
    AppleVerification::LiveValidation::Result.new(
      started_at: started_at,
      finished_at: started_at + 90.minutes,
      repeats: 2,
      environment: { "host" => "Apple M1 Pro", "tart" => "2.37.0", "control_plane" => "main@456eccb" },
      evidence: evidence_rows
    )
  end

  let(:evidence_rows) do
    [
      passed_row("functional-smoke-ios-app"),
      passed_row("functional-smoke-ios-app"),
      gap_row("functional-colormatching-ios"),
      passed_row("network-direct-ip"),
      failed_row("isolation-keychain")
    ]
  end

  def passed_row(scenario_id)
    AppleVerification::LiveValidation::Evidence.new(
      scenario_id: scenario_id, status: :passed, detail: "observed", references: [], recorded_at: started_at
    )
  end

  def failed_row(scenario_id)
    AppleVerification::LiveValidation::Evidence.new(
      scenario_id: scenario_id, status: :failed, detail: "keychain reachable", references: [], recorded_at: started_at
    )
  end

  def gap_row(scenario_id)
    AppleVerification::LiveValidation::Evidence.new(
      scenario_id: scenario_id, status: :gap, detail: "not executed", references: [], recorded_at: started_at
    )
  end


  it "renders run metadata" do
    expect(markdown).to include("# RDR-068 Live Validation Report")
    expect(markdown).to include("Apple M1 Pro")
    expect(markdown).to include("repeats: 2")
    expect(markdown).to include("main@456eccb")
  end

  it "marks a criterion satisfied only when every scenario passed" do
    ac1 = markdown.lines.find { |line| line.include?("| AC1 |") }
    ac2 = markdown.lines.find { |line| line.include?("| AC2 |") }

    expect(ac1).to include("satisfied")
    expect(ac1).not_to include("unmet")
    expect(ac2).to include("unmet")
    expect(ac2).not_to include("satisfied")
  end

  it "marks criteria without evidence unmet" do
    { "AC3" => "0 scenarios executed", "AC4" => "0 scenarios executed", "AC5" => "0/1 scenarios passed",
      "AC6" => "4 not executed", "AC7" => "0 scenarios executed", "AC8" => "0 scenarios executed" }.each do |criterion, evidence|
      line = markdown.lines.find { |row| row.include?("| #{criterion} |") }

      expect(line).to include("unmet")
      expect(line).to include(evidence)
    end
  end

  it "keeps a criterion unmet while any of its scenarios was never executed" do
    ac6 = markdown.lines.find { |line| line.include?("| AC6 |") }

    expect(ac6).to include("unmet")
    expect(ac6).to include("1/1 scenarios passed (4 not executed)")
  end

  it "lists failed and gap evidence in a gaps section for the next closeout" do
    expect(markdown).to include("## Gaps")
    expect(markdown).to include("isolation-keychain")
    expect(markdown).to include("keychain reachable")
    expect(markdown).to include("functional-colormatching-ios")
    expect(markdown).to include("not executed")
  end

  it "renders evidence rows grouped by scenario group" do
    expect(markdown).to include("## Functional evidence")
    expect(markdown).to include("functional-smoke-ios-app")
    expect(markdown).to include("## Network policy evidence")
    expect(markdown).to include("network-direct-ip")
  end

  it "records the archive convention and cross-reference requirement" do
    expect(markdown).to include("docs/rdrs/live-validation-2026-09-22-rdr-068.md")
    expect(markdown).to include("next RDR-068 closeout")
  end
end
