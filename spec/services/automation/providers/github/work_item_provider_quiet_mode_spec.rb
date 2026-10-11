# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Github::WorkItemProvider do
  let(:project) { build_stubbed(:project, quiet_mode: true) }
  let(:client) { instance_double(GithubClient) }

  before { allow(client).to receive(:add_comment) }

  it "suppresses work-item comments" do
    # @spec QUIET-MODE-003
    provider = described_class.new(project, client: client)

    expect(provider.add_comment(repo: "acme/widget", number: 42, body: "status")).to be_nil
    expect(client).not_to have_received(:add_comment)
  end

  it "suppresses repository comments" do
    # @spec QUIET-MODE-003
    provider = Automation::Providers::Github::RepositoryProvider.new(project, client: client)

    expect(provider.add_comment(repo: "acme/widget", number: 42, body: "status")).to be_nil
    expect(client).not_to have_received(:add_comment)
  end
end
