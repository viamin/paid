# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::DiscoverRdrArtifacts do
  def branch(sha = "a" * 40)
    Struct.new(:object).new(Struct.new(:sha).new(sha))
  end

  def tree(entries, truncated: false)
    Struct.new(:tree, :truncated).new(entries, truncated)
  end

  def project_for(client:, convention: {})
    instance_double(Project, full_name: "viamin/color_matching", default_branch: "main",
      effective_repo_profile: { "rdr_convention" => convention }, client:)
  end

  it "discovers conventional RDR files without a feature design pull request" do
    entry = Struct.new(:path, :type, :sha).new("docs/rdrs/RDR-063-example.md", "blob", "b" * 40)
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true).and_return(tree([ entry ]))
    allow(client).to receive(:file_content).with("viamin/color_matching", path: entry.path, ref: "a" * 40).and_return("Implements #101")

    discovery = described_class.call(project:)

    expect(discovery).to be_complete
    expect(discovery.directory_status).to eq(:matching_files)
    expect(discovery.artifacts).to contain_exactly(have_attributes(path: entry.path, revision: "a" * 40, body: "Implements #101"))
  end

  it "returns unavailable coverage when the repository cannot be accessed" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_raise(GithubClient::AuthenticationError, "forbidden")

    discovery = described_class.call(project:)

    expect(discovery).not_to be_complete
    expect(discovery.directory_status).to eq(:unavailable)
    expect(discovery.artifacts).to contain_exactly(have_attributes(path: "docs/rdrs", revision: "main", body: nil))
  end

  it "returns unavailable coverage for a truncated tree" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true).and_return(tree([], truncated: true))

    discovery = described_class.call(project:)

    expect(discovery).not_to be_complete
    expect(discovery.directory_status).to eq(:unavailable)
    expect(discovery.artifacts).to contain_exactly(have_attributes(path: "docs/rdrs", revision: "a" * 40, body: nil))
  end

  it "does not treat a missing or deleted repository as an absent design directory" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_raise(GithubClient::NotFoundError, "not found")

    discovery = described_class.call(project:)

    expect(discovery).not_to be_complete
    expect(discovery.artifacts.sole).to have_attributes(path: "docs/rdrs", body: nil)
  end

  it "keeps transient tree failures unavailable rather than inferring a missing directory" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true)
      .and_raise(Faraday::ConnectionFailed, "connection refused")

    discovery = described_class.call(project:)

    expect(discovery).not_to be_complete
    expect(discovery.artifacts.sole).to have_attributes(path: "docs/rdrs", revision: "a" * 40, body: nil)
  end

  it "treats a complete tree without docs/rdrs as successful empty discovery for the sanitized no-directory example" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true)
      .and_return(tree([ Struct.new(:path, :type).new("README.md", "blob") ]))

    discovery = described_class.call(project:)

    expect(discovery).to be_complete
    expect(discovery.directory_status).to eq(:absent)
    expect(discovery.artifacts).to be_empty
  end

  it "treats empty and non-matching configured directories as successful empty discovery" do
    client = instance_double(GithubClient)
    project = project_for(client:, convention: { "directory" => "architecture/decisions", "file_pattern" => "ADR-*.md" })
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true)
      .and_return(tree([ Struct.new(:path, :type).new("architecture/decisions/README.md", "blob") ]))

    discovery = described_class.call(project:)

    expect(discovery).to be_complete
    expect(discovery.directory_status).to eq(:no_matching_files)
    expect(discovery.artifacts).to be_empty
  end

  it "distinguishes a verified empty configured directory from an absent directory" do
    client = instance_double(GithubClient)
    project = project_for(client:)
    empty_directory = Struct.new(:path, :type).new("docs/rdrs", "tree")
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true).and_return(tree([ empty_directory ]))

    discovery = described_class.call(project:)

    expect(discovery).to be_complete
    expect(discovery).to have_attributes(directory_status: :empty, artifacts: [])
  end

  it "keeps an unreadable individual configured artifact unavailable at the pinned revision" do
    entry = Struct.new(:path, :type).new("architecture/decisions/ADR-063-example.md", "blob")
    client = instance_double(GithubClient)
    project = project_for(client:, convention: { "directory" => "architecture/decisions", "file_pattern" => "ADR-*.md" })
    allow(client).to receive(:ref).with("viamin/color_matching", "heads/main").and_return(branch)
    allow(client).to receive(:tree).with("viamin/color_matching", "a" * 40, recursive: true).and_return(tree([ entry ]))
    allow(client).to receive(:file_content).with("viamin/color_matching", path: entry.path, ref: "a" * 40)
      .and_raise(Faraday::ConnectionFailed, "connection refused")

    discovery = described_class.call(project:)

    expect(discovery).to be_complete
    expect(discovery.artifacts).to contain_exactly(have_attributes(path: entry.path, revision: "a" * 40, body: nil))
  end
end
