# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-001
RSpec.describe Automation::Providers::Data::Issue do
  it "is an immutable Data class with the documented fields" do
    dep = Automation::Providers::Data::Dependency.new(
      relation: :blocked_by, target_repo: "x/y", target_number: 42
    )
    issue = described_class.new(
      number: 7, title: "t", body: "b", state: :open, raw_state: "open",
      author_login: "alice", assignee_logins: [ "bob" ], labels: [ "bug" ],
      dependencies: [ dep ], created_at: Time.at(0), updated_at: Time.at(1),
      closed_at: nil, url: nil, pull_request_number: nil
    )

    expect(issue.dependencies).to eq([ dep ])
    expect(issue.state).to eq(:open)
  end

  it "declares the provider-neutral state enum" do
    expect(described_class::STATES).to contain_exactly(:open, :closed)
  end

  it "converts to the unified contract without discarding provider-native detail" do
    dep = Automation::Providers::Data::Dependency.new(
      relation: :related_to, target_repo: "x/y", target_number: 42
    )
    issue = described_class.new(
      number: 7, title: "t", body: "b", state: :open, raw_state: "open",
      author_login: "alice", assignee_logins: [ "bob" ], labels: [ "bug" ],
      dependencies: [ dep ], created_at: Time.at(0), updated_at: Time.at(1),
      closed_at: nil, url: nil, pull_request_number: nil
    )

    work_item = issue.to_work_item(container_id: "x/y")

    expect(work_item.identity).to have_attributes(provider: :github, resource_type: :issue, resource_id: "7")
    expect(work_item.relations.map(&:kind)).to eq([ :relates_to ])
    expect(work_item.relations.map(&:raw_kind)).to eq([ :related_to ])
    expect(work_item.relations.map(&:target)).to eq([ dep ])
    expect(work_item.assignments.map(&:provenance)).to eq([ :provider ])
    expect(work_item.raw_payload).to eq({})
  end

  describe Automation::Providers::Data::Dependency do
    it "is an immutable Data class capturing the relation and target" do
      dep = described_class.new(relation: :blocks, target_repo: "x/y", target_number: 3)
      expect(dep.relation).to eq(:blocks)
      expect(dep.target_number).to eq(3)
    end
  end
end
