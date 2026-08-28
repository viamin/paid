# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoMergeAttempts::PostPermissionComment do
  let(:project) { create(:project, auto_merge_mode: "dependabot_only") }
  let(:client) { instance_double(GithubClient) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:marker) { "<!-- paid: dependabot-merge-permission-rejection -->" }

  before do
    allow(project).to receive(:client).and_return(client)
    allow(client).to receive(:authenticated_login).and_return("paid-bot")
    allow(client).to receive(:add_comment)
  end

  def call
    described_class.call(
      project: project,
      pr_number: 42,
      marker: marker,
      title: "auto-merge blocked",
      intro: "The App could not merge this PR.",
      fallback_attempted: false,
      logger: logger,
      log_component: "test_component"
    )
  end

  context "when the marker is not present anywhere" do
    it "posts the comment" do
      allow(client).to receive(:recent_issue_comments).and_return([])

      call

      expect(client).to have_received(:add_comment)
    end
  end

  context "when the marker is only present on an older page" do
    let(:older_page_url) { "https://api.github.com/repos/acme/web/issues/42/comments?page=1" }
    let(:recent_comments) do
      page_url = older_page_url
      [].tap { |comments| comments.define_singleton_method(:next_older_page_url) { page_url } }
    end
    let(:existing_comment) { double(body: "#{marker} earlier", user: double(login: "paid-bot")) }

    before do
      allow(client).to receive(:recent_issue_comments).and_return(recent_comments)
      allow(client).to receive(:fetch_issue_comment_page).with(older_page_url).and_return([ existing_comment ])
    end

    it "walks older pages instead of re-posting on long-lived PRs" do
      call

      expect(client).to have_received(:fetch_issue_comment_page).with(older_page_url)
      expect(client).not_to have_received(:add_comment)
    end
  end

  context "when older pages exist but none contain the marker" do
    let(:older_page_url) { "https://api.github.com/repos/acme/web/issues/42/comments?page=1" }
    let(:recent_comments) do
      page_url = older_page_url
      [].tap { |comments| comments.define_singleton_method(:next_older_page_url) { page_url } }
    end

    before do
      allow(client).to receive(:recent_issue_comments).and_return(recent_comments)
      allow(client).to receive(:fetch_issue_comment_page).with(older_page_url).and_return([])
    end

    it "posts the comment after exhausting the comment history" do
      call

      expect(client).to have_received(:add_comment)
    end
  end

  context "when a matching marker comes from a different author" do
    it "posts the comment anyway" do
      spoof = double(body: "#{marker} earlier", user: double(login: "someone-else"))
      allow(client).to receive(:recent_issue_comments).and_return([ spoof ])

      call

      expect(client).to have_received(:add_comment)
    end
  end

  context "when fetching recent comments fails" do
    it "does not post a comment" do
      allow(client).to receive(:recent_issue_comments).and_raise(GithubClient::Error, "temporary outage")

      call

      expect(client).not_to have_received(:add_comment)
    end
  end
end
