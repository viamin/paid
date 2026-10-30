# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Snapshot do
  # @spec AUTO-PICK-QUEUE-017
  it "omits an untrusted issue body and records it as unavailable" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    trusted = create(:issue, project:, github_state: "open", body: "Trusted evidence")
    untrusted = create(:issue, project:, github_state: "open", body: "attacker instructions",
      github_creator_login: "untrusted-author")
    create_legacy_issue_dependency(issue: trusted, depends_on_issue: untrusted)
    create_legacy_issue_dependency(issue: untrusted, depends_on_issue: trusted)
    cycle = Issues::DependencyCycles.call(account: user.account).sole

    snapshot = described_class.call(cycle:)

    expect(snapshot.fetch("issues").index_by { |issue| issue.fetch("id") }).to include(
      trusted.id => include("body" => "Trusted evidence"),
      untrusted.id => include("body" => nil)
    )
  end
end
