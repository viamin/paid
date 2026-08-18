# frozen_string_literal: true

require "rails_helper"
require "psych"

class CodeqlWorkflowFile < Pathname
end

RSpec.describe CodeqlWorkflowFile, :no_db do
  subject(:workflow) do
    Psych.safe_load_file(
      Rails.root.join(".github/workflows/codeql.yml"),
      aliases: true
    )
  end

  def analyze_job
    workflow.fetch("jobs").fetch("analyze")
  end

  it "defines explicit ruby and actions analysis jobs" do
    expect(analyze_job.fetch("name")).to eq("Analyze (${{ matrix.language }})")
    expect(analyze_job.dig("strategy", "matrix", "language")).to eq(%w[actions ruby])
  end

  it "pins the CodeQL categories to the legacy default-setup language keys" do
    analyze_step = analyze_job.fetch("steps").find { |step| step["name"] == "Perform CodeQL Analysis" }

    expect(analyze_step.fetch("with")).to include(
      "category" => "/language:${{ matrix.language }}"
    )
  end

  it "uses the shared repository CodeQL config" do
    init_step = analyze_job.fetch("steps").find { |step| step["name"] == "Initialize CodeQL" }

    expect(init_step.fetch("with")).to include(
      "config-file" => "./.github/codeql/codeql-config.yml"
    )
  end

  it "uses the GitHub runner toolcache for the CodeQL bundle" do
    init_step = analyze_job.fetch("steps").find { |step| step["name"] == "Initialize CodeQL" }

    expect(init_step.fetch("with")).to include(
      "tools" => "toolcache"
    )
  end
end
