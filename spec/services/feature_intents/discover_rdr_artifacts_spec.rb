# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::DiscoverRdrArtifacts do
  it "discovers conventional RDR files without a feature design pull request" do
    entry = Struct.new(:path, :type, :sha).new("docs/rdrs/RDR-063-example.md", "file", "b" * 40)
    branch = Struct.new(:object).new(Struct.new(:sha).new("a" * 40))
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", effective_repo_profile: {}, client:)
    allow(client).to receive(:ref).with("acme/widget", "heads/main").and_return(branch)
    allow(client).to receive(:contents).with("acme/widget", path: "docs/rdrs", ref: "a" * 40).and_return([ entry ])
    allow(client).to receive(:file_content).with("acme/widget", path: "docs/rdrs/RDR-063-example.md", ref: "a" * 40).and_return("Implements #101")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: "docs/rdrs/RDR-063-example.md", revision: "a" * 40, body: "Implements #101"))
  end

  it "returns an unverifiable artifact when the RDR directory cannot be read" do
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", effective_repo_profile: {}, client:)
    allow(client).to receive(:ref).with("acme/widget", "heads/main").and_raise(GithubClient::Error, "forbidden")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: "docs/rdrs", revision: "main", body: nil))
  end

  it "returns an unverifiable artifact when GitHub is temporarily unreachable" do
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", effective_repo_profile: {}, client:)
    allow(client).to receive(:ref).with("acme/widget", "heads/main").and_return(Struct.new(:object).new(Struct.new(:sha).new("a" * 40)))
    allow(client).to receive(:contents).with("acme/widget", path: "docs/rdrs", ref: "a" * 40)
      .and_raise(Faraday::ConnectionFailed, "connection refused")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: "docs/rdrs", revision: "main", body: nil))
  end

  it "uses the directory revision for every RDR body" do
    entry = Struct.new(:path, :type, :sha).new("docs/rdrs/RDR-063-example.md", "file", "b" * 40)
    branch = Struct.new(:object).new(Struct.new(:sha).new("a" * 40))
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", effective_repo_profile: {}, client:)
    allow(client).to receive(:ref).with("acme/widget", "heads/main").and_return(branch)
    allow(client).to receive(:contents).with("acme/widget", path: "docs/rdrs", ref: "a" * 40).and_return([ entry ])

    expect(client).to receive(:file_content).with("acme/widget", path: entry.path, ref: "a" * 40).and_return("Implements #101")

    described_class.call(project:)
  end

  it "uses the project's configured RDR directory and filename convention" do
    entry = Struct.new(:path, :type).new("architecture/decisions/ADR-063-example.md", "file")
    branch = Struct.new(:object).new(Struct.new(:sha).new("a" * 40))
    client = instance_double(GithubClient)
    project = instance_double(
      Project,
      full_name: "acme/widget",
      default_branch: "main",
      effective_repo_profile: { "rdr_convention" => { "directory" => "architecture/decisions", "file_pattern" => "ADR-*.md" } },
      client:
    )
    allow(client).to receive(:ref).with("acme/widget", "heads/main").and_return(branch)
    allow(client).to receive(:contents).with("acme/widget", path: "architecture/decisions", ref: "a" * 40).and_return([ entry ])
    allow(client).to receive(:file_content).with("acme/widget", path: entry.path, ref: "a" * 40).and_return("Implements: #101")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: entry.path, revision: "a" * 40, body: "Implements: #101"))
  end
end
