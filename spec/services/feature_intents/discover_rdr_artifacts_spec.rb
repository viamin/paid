# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::DiscoverRdrArtifacts do
  it "discovers conventional RDR files without a feature design pull request" do
    entry = Struct.new(:path, :type, :sha).new("docs/rdrs/RDR-063-example.md", "file", "b" * 40)
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", client:)
    allow(client).to receive(:contents).with("acme/widget", path: "docs/rdrs", ref: "main").and_return([ entry ])
    allow(client).to receive(:file_content).with("acme/widget", path: "docs/rdrs/RDR-063-example.md", ref: "main").and_return("Implements #101")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: "docs/rdrs/RDR-063-example.md", revision: "b" * 40, body: "Implements #101"))
  end

  it "returns an unverifiable artifact when the RDR directory cannot be read" do
    client = instance_double(GithubClient)
    project = instance_double(Project, full_name: "acme/widget", default_branch: "main", client:)
    allow(client).to receive(:contents).with("acme/widget", path: "docs/rdrs", ref: "main").and_raise(GithubClient::Error, "forbidden")

    artifacts = described_class.call(project:)

    expect(artifacts).to contain_exactly(have_attributes(path: "docs/rdrs", revision: "main", body: nil))
  end
end
