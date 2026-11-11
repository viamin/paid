# frozen_string_literal: true

require "rails_helper"

RSpec.describe "agent_runs/_criterion_evidence", :no_db, type: :view do
  # @spec LIVE-PREVIEW-013
  it "separates a verified input receipt from the unverified semantic conclusion" do
    agent_run = Struct.new(:verification_result).new({
      "evidence" => { "coverage" => [ {
        "id" => "AC-1", "reported_status" => "passed", "state" => "unverified",
        "reported_verification" => {
          "rationale" => "The system test exercises settings persistence.",
          "limitations" => [ "It does not cover every settings variant." ]
        },
        "input_receipt" => { "state" => "verified", "references" => [ { "path" => "spec/system/settings_spec.rb", "state" => "verified" } ] }
      } ] }
    })

    render partial: "agent_runs/criterion_evidence", locals: { agent_run: }

    expect(rendered).to include("Semantic coverage: Unverified.")
    expect(rendered).to include("Rationale: The system test exercises settings persistence.")
    expect(rendered).to include("Limitations:")
    expect(rendered).to include("It does not cover every settings variant.")
    expect(rendered).to include("Input receipt: Verified.")
    expect(rendered).to include("spec/system/settings_spec.rb: verified")
  end

  # @spec LIVE-PREVIEW-013
  it "shows the mechanical verdict reason for every cited input" do
    agent_run = Struct.new(:verification_result).new({
      "evidence" => { "coverage" => [ {
        "id" => "AC-1", "reported_status" => "passed", "state" => "unverified",
        "reported_verification" => { "rationale" => "Reported inputs." },
        "input_receipt" => {
          "state" => "contradicted",
          "references" => [ {
            "path" => "spec/system/settings_spec.rb", "state" => "contradicted",
            "verdict_reason" => "content_digest_mismatch"
          } ]
        }
      } ] }
    })

    render partial: "agent_runs/criterion_evidence", locals: { agent_run: }

    expect(rendered).to include("Input receipt: Contradicted.")
    expect(rendered).to include("spec/system/settings_spec.rb: contradicted — Content digest mismatch")
  end
end
