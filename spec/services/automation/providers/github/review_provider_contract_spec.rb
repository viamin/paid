# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Automation::Providers::Github::ReviewProvider do
  context "with contract verification" do
  let(:client) { instance_double(GithubClient) }
  let(:project_class) do
    Class.new do
      def full_name = "acme/widgets"
    end
  end
  let(:project) { project_class.new }
  let(:adapter) { described_class.new(project, client: client) }
  let(:repo) { "acme/widgets" }
  let(:pr_number) { 42 }

  before do
    allow(client).to receive_messages(
      pull_request_reviews: [
        { id: 1, user_login: "Alice", state: "APPROVED",
          body: "lgtm", submitted_at: Time.utc(2026, 1, 1), commit_id: "abc" }
      ],
      review_threads: [],
      pull_request_review_requests: { users: [ "alice" ], teams: [] },
      resolve_review_thread: nil
    )
    allow(client).to receive(:request_pull_request_review)
    allow(client).to receive(:create_pull_request_review).and_return(
      OpenStruct.new(
        id: 7, body: "lgtm", state: "APPROVED",
        submitted_at: Time.utc(2026, 1, 1), commit_id: "abc",
        user: OpenStruct.new(login: "bot")
      )
    )
  end

    it_behaves_like "a ReviewProvider implementation"
  end
end
