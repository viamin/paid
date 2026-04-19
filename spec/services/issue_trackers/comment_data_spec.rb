# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::CommentData do
  it "creates with required fields" do
    comment = described_class.new(external_id: "c-1", body: "Test comment")

    expect(comment.external_id).to eq("c-1")
    expect(comment.body).to eq("Test comment")
    expect(comment.author).to be_nil
    expect(comment.created_at).to be_nil
  end

  it "creates with all fields" do
    now = Time.current
    comment = described_class.new(
      external_id: "c-2",
      body: "Comment body",
      author: "user@example.com",
      created_at: now
    )

    expect(comment.author).to eq("user@example.com")
    expect(comment.created_at).to eq(now)
  end

  it "is frozen" do
    comment = described_class.new(external_id: "1", body: "Test")

    expect(comment).to be_frozen
  end
end
