# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::ExternalPrerequisites do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, owner: "paid", repo: "paid") }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

  def dependency_attributes(dependency)
    { depends_on_owner: dependency.fetch("owner"), depends_on_repo: dependency.fetch("repo"),
      depends_on_number: dependency.fetch("number") }
  end

  def notification_for(dependency)
    create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Agent harness support needs external work",
      description: "Wait for viamin/agent-harness#517 to close.",
      metadata: { "prerequisites" => [ {
        "identity" => "external-517", "criterion" => "Agent harness support", "kind" => "external",
        "external_dependency" => dependency
      } ] })
  end

  it "releases an external wait after its tracked target closes" do # @spec PARTIAL-CLOSEOUT-038
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "Agent Harness")
    target = create(:issue, project: target_project, github_number: 517, github_state: "open", paid_state: "in_progress")
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    create(:issue_dependency, issue:, depends_on_issue: nil, **dependency_attributes(dependency))
    notification = notification_for(dependency)

    expect(described_class.call(target)).to be_empty
    expect(notification.reload).to be_active

    target.update!(github_state: "closed")

    expect(notification.reload).not_to be_active
    expect(notification.metadata).to include("released_by" => "external_prerequisite")
  end

  it "releases an unavailable wait when its target is first synced as resolved" do # @spec PARTIAL-CLOSEOUT-038
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "Agent Harness")
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    create(:issue_dependency, issue:, depends_on_issue: nil, **dependency_attributes(dependency))
    notification = notification_for(dependency)

    expect(described_class.states_for(notification).sole).to include("state" => "unavailable")

    create(:issue, project: target_project, github_number: 517, github_state: "closed", paid_state: "completed")

    expect(notification.reload).not_to be_active
    expect(notification.metadata).to include("released_by" => "external_prerequisite")
  end

  it "keeps stale external state held with a recheck path" do # @spec PARTIAL-CLOSEOUT-038
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    notification = notification_for(dependency)

    status = described_class.status_for(issue, dependency)

    expect(status).to include("state" => "unavailable", "reference" => "viamin/agent-harness#517")
    expect(status.fetch("recovery")).to include("sync")
    expect(notification).to be_active
  end

  it "upgrades the legacy #4726-style wait only when it has no human evidence contract" do # @spec PARTIAL-CLOSEOUT-038
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "agent-harness")
    target = create(:issue, project: target_project, github_number: 517, github_state: "open", paid_state: "in_progress")
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    create(:issue_dependency, issue:, depends_on_issue: nil, **dependency_attributes(dependency))
    notification = create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Wait for #517", description: "Wait for viamin/agent-harness#517 before continuation.",
      metadata: { "prerequisites" => [ { "identity" => "legacy", "kind" => "human" } ] })

    target.update!(github_state: "closed")

    expect(notification.reload).not_to be_active
    expect(notification.metadata.fetch("prerequisites").sole).to include("kind" => "external")
  end

  it "does not convert a human policy hold when its dependency changes" do # @spec PARTIAL-CLOSEOUT-038
    target_project = create(:project, account:, owner: "viamin", repo: "agent-harness", name: "agent-harness")
    target = create(:issue, project: target_project, github_number: 517, github_state: "open", paid_state: "in_progress")
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    create(:issue_dependency, issue:, depends_on_issue: nil, **dependency_attributes(dependency))
    notification = create(:notification, :error, account:, subject: issue,
      source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
      title: "Design approval", description: "Wait for #517 and record approval.",
      metadata: { "references" => [ { "kind" => "policy" } ],
        "prerequisites" => [ { "identity" => "human-policy", "kind" => "human" } ] })

    target.update!(github_state: "closed")

    expect(notification.reload).to be_active
    expect(notification.metadata.fetch("prerequisites").sole).to include("kind" => "human")
  end

  it "does not release a different account's prerequisite" do # @spec PARTIAL-CLOSEOUT-038
    other_account = create(:account)
    target_project = create(:project, account: other_account, owner: "viamin", repo: "agent-harness", name: "agent-harness")
    target = create(:issue, project: target_project, github_number: 517, github_state: "closed")
    dependency = { "owner" => "viamin", "repo" => "agent-harness", "number" => 517 }
    create(:issue_dependency, issue:, depends_on_issue: nil, **dependency_attributes(dependency))
    notification = notification_for(dependency)

    described_class.call(target)

    expect(notification.reload).to be_active
  end
end
