# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::DetectLidMode do
  let(:project) { create(:project) }
  let(:repo_path) { Pathname(RSpec.current_example.metadata.fetch(:tmpdir)) }

  around do |example|
    Dir.mktmpdir do |dir|
      example.metadata[:tmpdir] = dir
      example.run
    end
  end

  def write_repo_file(relative_path, content)
    path = repo_path.join(relative_path)
    path.dirname.mkpath
    path.write(content)
  end

  it "detects full mode from the LID block and persists detection metadata" do
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: Full
      - Version: 1.3.0
    MD
    write_repo_file("docs/high-level-design.md", "# HLD\n")
    write_repo_file("docs/intent/auth/auth-design.md", "# Auth\n")

    result = described_class.call(project:, repo_path:)

    expect(result).to include(
      mode: "full",
      version: "1.3.0",
      sources: [ "AGENTS.md ## LID block" ]
    )
    expect(project.reload.lid_mode).to eq("full")
    expect(project.lid_detection).to include(
      "version" => "1.3.0",
      "sources" => [ "AGENTS.md ## LID block" ]
    )
    expect(project.lid_detection["detected_at"]).to be_present
    expect(project.lid_detection["warnings"]).to eq([])
  end

  it "falls back to artifact detection when no LID block is present" do
    write_repo_file("docs/high-level-design.md", "# HLD\n")
    write_repo_file("docs/intent/payments/payments-design.md", "# Payments\n")
    write_repo_file("docs/arrows/index.yaml", "version: 1\n")

    result = described_class.call(project:, repo_path:)

    expect(result[:mode]).to eq("full")
    expect(result[:version]).to be_nil
    expect(result[:sources]).to contain_exactly(
      "docs/intent/",
      "docs/high-level-design.md",
      "docs/arrows/index.yaml"
    )
    expect(project.reload.lid_mode).to eq("full")
  end

  it "defaults malformed mode declarations to full and records a warning" do
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: sideways
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:)

    expect(result[:mode]).to eq("full")
    expect(result[:warnings]).to include("Invalid LID mode in AGENTS.md; defaulted to Full.")
    expect(project.reload.lid_detection["warnings"]).to include("Invalid LID mode in AGENTS.md; defaulted to Full.")
  end

  it "keeps scoped mode and warns when the LID Scope section is missing" do
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: Scoped
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:)

    expect(result[:mode]).to eq("scoped")
    expect(result[:warnings]).to include("Scoped LID declared without a ## LID Scope section; defaulting future scope checks to in-scope.")
    expect(project.reload.lid_mode).to eq("scoped")
  end

  # @spec LID-DETECTION-001
  it "falls back to CLAUDE.md when AGENTS.md exists but lacks a LID block" do
    write_repo_file("AGENTS.md", <<~MD)
      # Project agent instructions

      No LID configuration here.
    MD
    write_repo_file("CLAUDE.md", <<~MD)
      ## LID

      - Mode: Full
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:)

    expect(result).to include(
      mode: "full",
      version: "1.3.0",
      sources: [ "CLAUDE.md ## LID block" ]
    )
    expect(project.reload.lid_mode).to eq("full")
  end

  it "clears lid mode when no directives or artifacts are present" do
    project.update!(lid_mode: "full", lid_detection: { "version" => "1.2.0" })

    result = described_class.call(project:, repo_path:)

    expect(result).to include(mode: nil, version: nil, sources: [])
    expect(project.reload.lid_mode).to be_nil
    expect(project.lid_detection).to include("sources" => [], "warnings" => [])
  end

  it "warns when LID is declared but standard design docs are absent" do
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: Full
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:)

    expect(result[:mode]).to eq("full")
    expect(result[:warnings]).to include(
      "LID declared in instruction file, but standard design docs (docs/high-level-design.md, docs/intent/) are absent; agents may waste tokens searching for them."
    )
    expect(project.reload.lid_detection["warnings"]).to include(
      "LID declared in instruction file, but standard design docs (docs/high-level-design.md, docs/intent/) are absent; agents may waste tokens searching for them."
    )
  end

  # @spec LID-DETECTION-008
  it "does not overwrite a manually overridden lid mode during background detection" do
    project.update!(lid_mode: "scoped", lid_mode_overridden: true)
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: Full
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:)

    expect(result[:mode]).to eq("full")
    expect(project.reload.lid_mode).to eq("scoped")
    expect(project.lid_mode_overridden?).to be true
    expect(project.lid_detection).to include("version" => "1.3.0")
  end

  # @spec LID-DETECTION-008
  it "applies the detected mode and clears the override when forced" do
    project.update!(lid_mode: "scoped", lid_mode_overridden: true)
    write_repo_file("AGENTS.md", <<~MD)
      ## LID

      - Mode: Full
      - Version: 1.3.0
    MD

    result = described_class.call(project:, repo_path:, force: true)

    expect(result[:mode]).to eq("full")
    expect(project.reload.lid_mode).to eq("full")
    expect(project.lid_mode_overridden?).to be false
  end
end
