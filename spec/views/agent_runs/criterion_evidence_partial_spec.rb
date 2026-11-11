# frozen_string_literal: true

require "rails_helper"

RSpec.describe "agent_runs/_criterion_evidence", :no_db, type: :view do
  # @spec LIVE-PREVIEW-014
  let(:agent_run) do
    Struct.new(:verification_result).new({ "evidence" => { "coverage" => coverage } })
  end

  let(:coverage) do
    [
      {
        "id" => "AC-1",
        "reported_status" => "passed",
        "state" => "unverified",
        "reason" => "no_recorder_owned_assertion_for_criterion",
        "reported_verification" => {
          "kind" => "unit_or_service_test",
          "rationale" => "The service spec exercises the changed rule.",
          "limitations" => "Does not cover the browser UI.",
          "inputs" => [
            { "type" => "repo_path", "path" => "spec/services/settings_spec.rb", "commit" => "a" * 40 },
            { "type" => "test_run", "command" => "bin/rspec spec/services/settings_spec.rb", "result" => "passed" }
          ]
        },
        "input_receipt" => {
          "state" => "verified",
          "reason" => "input_references_verified",
          "references" => [
            { "type" => "repo_path", "locator" => "spec/services/settings_spec.rb", "state" => "verified", "reason" => "digest_match" },
            { "type" => "test_run", "locator" => "bin/rspec spec/services/settings_spec.rb", "state" => "unavailable", "reason" => "no_recorder_owned_execution" }
          ]
        }
      },
      {
        "id" => "AC-2",
        "reported_status" => "skipped",
        "state" => "skipped",
        "reason" => "reported_skipped"
      }
    ]
  end

  it "renders the rationale, inputs, receipts, and semantic judgment together" do
    render partial: "agent_runs/criterion_evidence", locals: { agent_run: agent_run }

    expect(rendered).to include("Criterion evidence")
    expect(rendered).to include("AC-1")
    expect(rendered).to include("The service spec exercises the changed rule.")
    expect(rendered).to include("Does not cover the browser UI.")
    expect(rendered).to include("spec/services/settings_spec.rb")
    expect(rendered).to include("verified")
    expect(rendered).to include("unverified")
  end

  it "keeps verified inputs distinguishable from the still-reviewable conclusion" do
    render partial: "agent_runs/criterion_evidence", locals: { agent_run: agent_run }

    expect(rendered).to have_selector("[data-testid='criterion-input-receipt-state'][data-state='verified']")
    expect(rendered).to have_selector("[data-testid='criterion-coverage-state'][data-state='unverified']")
    expect(rendered).to include("Inputs verified do not prove the semantic coverage claim")
  end

  it "keeps missing or unverifiable evidence explicit" do
    render partial: "agent_runs/criterion_evidence", locals: { agent_run: agent_run }

    expect(rendered).to include("AC-2")
    expect(rendered).to include("skipped")
    expect(rendered).to include("No input receipt recorded for this criterion")
  end
end
