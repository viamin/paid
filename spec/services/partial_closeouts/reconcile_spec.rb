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
    allow(client).to receive(:issue) { OpenStruct.new(body: parent.body.to_s) }
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

  # @spec NO-OUTPUT-ISSUE-007
  it "labels a created owner issue for automation and generated routing" do
    created = OpenStruct.new(number: 445, html_url: "https://example.test/issues/445", id: 445, title: "Finish dispatch", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(create(:issue, project: project, github_number: 445))

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).to have_received(:create_issue).with(
      project.full_name,
      hash_including(labels: %w[paid-automation paid-generated])
    )
  end

  it "raises the intended validation when the agent gap omits a title" do
    created = OpenStruct.new(number: 446, html_url: "https://example.test/issues/446", id: 446, title: "Fallback", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(create(:issue, project: project, github_number: 446))

    expect {
      described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "body" => "Wire dispatch" } ]))
    }.to raise_error(ArgumentError, "agent gap title is required")
    expect(client).not_to have_received(:create_issue)
  end

  it "falls back to a generic next step when a human gap omits next_step" do
    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "sign-off", "kind" => "human" } ]))

    notification = Notification.find_by(subject: parent, blocking: true)
    expect(notification.description).to include("Review the recorded partial-closeout prerequisite.")
  end

  it "publishes one aggregated notification covering every human prerequisite" do
    described_class.call(agent_run: run, assessment: gaps([
      { "criterion" => "macOS acceptance", "kind" => "human", "next_step" => "Run the approved macOS pilot." },
      { "criterion" => "security sign-off", "kind" => "human", "next_step" => "Approve the audit in the portal." }
    ]))

    notifications = Notification.where(subject: parent, blocking: true)
    expect(notifications.count).to eq(1)
    expect(notifications.first.title).to eq("2 partial-closeout prerequisites need operator action")
    expect(notifications.first.description).to include("macOS acceptance: Run the approved macOS pilot.")
    expect(notifications.first.description).to include("security sign-off: Approve the audit in the portal.")
  end

  it "does not attach the parent issue to itself when reuse guesses its number" do
    created = OpenStruct.new(number: 447, html_url: "https://example.test/issues/447", id: 447, title: "Finish dispatch", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(create(:issue, project: project, github_number: 447))

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => parent.github_number, "title" => "Finish dispatch" } ]))

    expect(parent.issue_dependencies.where(depends_on_issue: parent)).to be_empty
    expect(IssueDependency.where(issue: parent).count).to eq(1)
  end

  it "writes dependency lines through the project's configured conventions" do
    create(:project_convention_override,
      project: project,
      key: "issue_dependency_format",
      value: { "depends_on_prefix" => "Requires", "blocked_by_prefix" => "Awaits", "heading" => "## Blockers" })
    owner = create(:issue, project: project, github_state: "open", paid_state: "new")

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => owner.github_number } ]))

    expect(client).to have_received(:update_issue).with(
      project.full_name, parent.github_number,
      body: a_string_including("## Blockers").and(a_string_including("- Requires ##{owner.github_number}"))
    )
  end

  it "appends under the existing heading instead of adding a second one" do
    parent.update!(body: "Original body\n\n## Dependencies\n\n- Depends on #1")
    owner = create(:issue, project: project, github_state: "open", paid_state: "new")

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => owner.github_number } ]))

    expect(client).to have_received(:update_issue) do |_, _, body:|
      expect(body.scan("## Dependencies").count).to eq(1)
      expect(body).to include("- Depends on ##{owner.github_number}")
    end
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "rewrites from the live GitHub body so human edits made since the last sync survive" do
    parent.update!(body: "Stale local body")
    owner = create(:issue, project: project, github_state: "open", paid_state: "new")
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: "Human-edited body\n\n## Notes\n\nedited on GitHub"))

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => owner.github_number } ]))

    expect(client).to have_received(:update_issue) do |_, _, body:|
      expect(body).to include("Human-edited body")
      expect(body).not_to include("Stale local body")
      expect(body).to include("- Depends on ##{owner.github_number}")
    end
    expect(parent.reload.body).to include("Human-edited body")
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "inserts new lines inside the dependencies section when later sections follow the heading" do
    allow(client).to receive(:issue).and_return(OpenStruct.new(
      body: "Original body\n\n## Dependencies\n\n- Depends on #1\n\n## Acceptance\n\n- criterion A"
    ))
    owner = create(:issue, project: project, github_state: "open", paid_state: "new")

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "owner_issue_number" => owner.github_number } ]))

    expect(client).to have_received(:update_issue) do |_, _, body:|
      dependencies_section = body[/## Dependencies\n.*?(?=\n## |\z)/m]
      expect(dependencies_section).to include("- Depends on ##{owner.github_number}")
      expect(body).to include("## Acceptance\n\n- criterion A")
    end
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "resumes from a marker on an already-synced local issue without filing again" do
    allow(client).to receive(:create_issue)
    existing = create(:issue, project: project, github_state: "open",
      body: "Wire dispatch\n\n<!-- paid:partial-closeout:#{run.id}:0 -->")

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).not_to have_received(:create_issue)
    expect(parent.issue_dependencies.find_by(depends_on_issue: existing)).to be_present
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "records the created number before the local upsert so a crash mid-reconcile does not duplicate the issue" do
    created = OpenStruct.new(number: 448, html_url: "https://example.test/issues/448", id: 448, title: "Finish dispatch", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_raise(StandardError, "upsert crashed")

    expect {
      described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))
    }.to raise_error(StandardError, "upsert crashed")
    expect(run.reconciliation.dig("gaps", "0", "owner_issue_number")).to eq(448)

    # A later sync landed the created issue locally; the retry must reuse it.
    synced = create(:issue, project: project, github_number: 448, github_state: "open")
    allow(Issues::UpsertFromGithub).to receive(:call).and_call_original

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).to have_received(:create_issue).once
    expect(parent.reload.issue_dependencies.find_by(depends_on_issue: synced)).to be_present
    expect(run.reload.reconciliation.fetch("status")).to eq("reconciled")
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "recovers a remotely created marked issue after a crash before its number is persisted" do
    marker = "<!-- paid:partial-closeout:#{run.id}:0 -->"
    remote_issue = OpenStruct.new(number: 449, html_url: "https://example.test/issues/449", id: 449, title: "Finish dispatch", body: "Wire dispatch\n\n#{marker}")
    synced = create(:issue, project: project, github_number: 449, github_state: "open")
    allow(client).to receive(:create_issue).and_raise(SystemExit, "worker crashed")

    expect {
      described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))
    }.to raise_error(SystemExit, "worker crashed")
    expect(run.reload.reconciliation.dig("gaps", "0", "marker")).to eq(marker)

    allow(run.project).to receive(:client).and_return(client)
    allow(client).to receive(:search_issues)
      .with(%(repo:#{project.full_name} is:issue state:open in:body "#{marker}"), per_page: 100)
      .and_return(OpenStruct.new(items: [ remote_issue ]))
    allow(Issues::UpsertFromGithub).to receive(:call).with(project:, github_issue: remote_issue).and_return(synced)

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).to have_received(:create_issue).once
    expect(parent.reload.issue_dependencies.find_by(depends_on_issue: synced)).to be_present
  end

  # @spec NO-OUTPUT-ISSUE-007
  it "creates an owner when a recorded attempt never reached GitHub" do
    marker = "<!-- paid:partial-closeout:#{run.id}:0 -->"
    run.update!(reconciliation: { "gaps" => { "0" => { "status" => "creating", "marker" => marker } } })
    created = OpenStruct.new(number: 450, html_url: "https://example.test/issues/450", id: 450, title: "Finish dispatch", body: "Wire dispatch\n\n#{marker}")
    owner = create(:issue, project: project, github_number: 450, github_state: "open")
    allow(client).to receive(:search_issues)
      .with(%(repo:#{project.full_name} is:issue state:open in:body "#{marker}"), per_page: 100)
      .and_return(OpenStruct.new(items: []))
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).with(project:, github_issue: created).and_return(owner)

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch", "body" => "Wire dispatch" } ]))

    expect(client).to have_received(:create_issue).once
    expect(parent.reload.issue_dependencies.find_by(depends_on_issue: owner)).to be_present
  end

  it "does not recover the parent itself from a recorded owner number" do
    run.update!(reconciliation: { "gaps" => { "0" => { "owner_issue_number" => parent.github_number, "status" => "creating" } } })
    created = OpenStruct.new(number: 449, html_url: "https://example.test/issues/449", id: 449, title: "Finish dispatch", body: "")
    allow(client).to receive(:create_issue).and_return(created)
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(create(:issue, project: project, github_number: 449))

    described_class.call(agent_run: run, assessment: gaps([ { "criterion" => "dispatch", "title" => "Finish dispatch" } ]))

    expect(client).to have_received(:create_issue).once
    expect(parent.issue_dependencies.where(depends_on_issue: parent)).to be_empty
  end

  def gaps(gaps)
    { "gaps" => gaps }
  end
end
