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
end
