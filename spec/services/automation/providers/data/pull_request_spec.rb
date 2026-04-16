# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::PullRequest do
  it "is an immutable Data class with the documented fields" do
    pr = described_class.new(
      number: 1, title: "t", body: "b", state: :open,
      draft: false, merged: false, mergeable: true,
      head_sha: "abc", head_ref: "f", base_ref: "main",
      author_login: "alice", labels: [ "a" ],
      created_at: Time.at(0), updated_at: Time.at(1),
      merged_at: nil, url: "http://example.com", raw_state: "open"
    )

    expect(pr).to have_attributes(
      number: 1, title: "t", state: :open, draft: false,
      head_sha: "abc", labels: [ "a" ]
    )
    expect { pr.number = 2 }.to raise_error(NoMethodError)
  end

  it "declares the provider-neutral state enum" do
    expect(described_class::STATES).to contain_exactly(:open, :closed)
  end
end
