# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe PartialCloseouts::Reconcile do
  let(:project) { create(:project) }
  let(:parent) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:run) { create(:agent_run, :completed, project: project, issue: parent, pull_request_number: 99) }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive(:update_issue)
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "reuses an open owner and persists a blocking dependency" do
    owner = create(:issue, project: project, github_state: "open", paid_state: "new")

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => owner.github_number } ]))

    expect(parent.issue_dependencies.find_by(depends_on_issue: owner)).to be_present
    expect(run.reload.reconciliation.fetch("status")).to eq("reconciled")
    expect(client).to have_received(:update_issue).with(project.full_name, parent.github_number, body: a_string_including("Depends on ##{owner.github_number}"))
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "does not let a closed historical issue satisfy an unimplemented gap" do
    create(:issue, project: project, github_state: "closed", paid_state: "completed")
    created = OpenStruct.new(number: 444, html_url: "https://example.test/issues/444", id: 444, title: "Finish dispatch", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(create(:issue, project: project, github_number: 444))

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).to have_received(:create_issue).once
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "routes a human prerequisite to the Inbox without retrying an agent" do
    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "macOS acceptance", "kind" => "human", "next_step" => "Run the approved macOS pilot." } ]))

    expect(Notification.where(subject: parent, blocking: true)).to exist
    expect(run.reload.reconciliation.fetch("status")).to eq("awaiting_operator")
  end

  def gaps(gaps)
    { "gaps" => gaps }
  end
end
