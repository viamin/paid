# frozen_string_literal: true

require "rails_helper"

# @spec LABEL-INTEGRATION-002
RSpec.describe Labels::WritePolicy do
  it "allows label writes only in read_write mode" do
    expect(described_class.allowed?(project: build(:project, label_integration_mode: "read_write"))).to be(true)
    expect(described_class.allowed?(project: build(:project, label_integration_mode: "read_only"))).to be(false)
    expect(described_class.allowed?(project: build(:project, label_integration_mode: "ignored"))).to be(false)
  end

  it "prevents the project GitHub client from issuing suppressed label writes" do
    project = build(:project, label_integration_mode: "read_only")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)
    allow(client).to receive(:add_labels_to_issue)

    expect(decorated.add_labels_to_issue(project.full_name, 1, [ "paid-ready" ])).to be_nil
    expect(client).not_to have_received(:add_labels_to_issue)
  end

  it "strips labels from issue creation but still creates the issue when writes are suppressed" do
    project = build(:project, label_integration_mode: "read_only")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)
    allow(client).to receive(:create_issue)

    decorated.create_issue(project.full_name, title: "Analysis", body: "body", labels: [ "paid-generated" ])

    expect(client).to have_received(:create_issue)
      .with(project.full_name, title: "Analysis", body: "body", labels: [])
  end

  it "keeps labels on issue creation in read_write mode" do
    project = build(:project, label_integration_mode: "read_write")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)
    allow(client).to receive(:create_issue)

    decorated.create_issue(project.full_name, title: "Analysis", body: "body", labels: [ "paid-generated" ])

    expect(client).to have_received(:create_issue)
      .with(project.full_name, title: "Analysis", body: "body", labels: [ "paid-generated" ])
  end

  it "strips labels from issue updates when writes are suppressed" do
    project = build(:project, label_integration_mode: "ignored")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)
    allow(client).to receive(:update_issue)

    decorated.update_issue(project.full_name, 1, body: "body", labels: [ "paid-generated" ])

    expect(client).to have_received(:update_issue).with(project.full_name, 1, body: "body")
  end

  it "keeps labels on issue updates in read_write mode" do
    project = build(:project, label_integration_mode: "read_write")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)
    allow(client).to receive(:update_issue)

    decorated.update_issue(project.full_name, 1, labels: [ "paid-generated" ])

    expect(client).to have_received(:update_issue).with(project.full_name, 1, labels: [ "paid-generated" ])
  end

  it "keeps the write policy after selecting a trusted human client" do
    project = build(:project, label_integration_mode: "read_only")
    trusted_client = instance_double(GithubClient)
    fallback_client = instance_double(GithubClient::WithFallback, trusted_human_mutation_client: trusted_client)
    decorated = GithubClient::LabelWriteSuppressing.new(fallback_client, project:)
    allow(trusted_client).to receive(:update_issue)

    decorated.trusted_human_mutation_client.update_issue(project.full_name, 1, labels: [ "paid-generated" ])

    expect(trusted_client).to have_received(:update_issue).with(project.full_name, 1)
  end

  it "keeps the decorator when the wrapped client cannot select a trusted human credential" do
    project = build(:project, label_integration_mode: "read_write")
    client = instance_double(GithubClient)
    decorated = GithubClient::LabelWriteSuppressing.new(client, project:)

    expect(decorated.trusted_human_mutation_client).to equal(decorated)
  end
end
