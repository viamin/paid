# frozen_string_literal: true

require "rails_helper"

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

  describe Automation::Providers::Data::Dependency do
    it "is an immutable Data class capturing the relation and target" do
      dep = described_class.new(relation: :blocks, target_repo: "x/y", target_number: 3)
      expect(dep.relation).to eq(:blocks)
      expect(dep.target_number).to eq(3)
    end
  end
end
