# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::ReviewThread do
  it "captures the thread id, resolution status, and comments" do
    comment = Automation::Providers::Data::ReviewThreadComment.new(
      author_login: "alice", body: "here", path: "a.rb", line: 10
    )
    thread = described_class.new(id: "T_1", resolved: false, comments: [ comment ])

    expect(thread.comments.first.path).to eq("a.rb")
  end
end
