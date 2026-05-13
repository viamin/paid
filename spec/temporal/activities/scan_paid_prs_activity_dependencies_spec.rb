# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ScanPaidPrsActivity, :no_db do
  subject(:activity) { described_class.new }

  let(:client) { instance_double(GithubClient) }
  let(:project) do
    Data.define(:full_name, :owner, :repo, :id).new(
      full_name: "acme/widgets",
      owner: "acme",
      repo: "widgets",
      id: 1
    )
  end
  let(:issue) do
    Data.define(:body, :github_number).new(
      body: body,
      github_number: 42
    )
  end
  let(:body) { "Depends on #41" }
  let(:comments) { [] }

  before do
    allow(client).to receive(:issue_comments)
      .with(project.full_name, issue.github_number)
      .and_return(comments)
  end

  describe "#dependencies_resolved?" do
    it "returns false when a same-repo dependency PR is unmerged" do
      allow(client).to receive(:pull_request)
        .with(project.full_name, 41)
        .and_return(OpenStruct.new(number: 41, merged: false, merged_at: nil))

      expect(activity.send(:dependencies_resolved?, client, project, issue)).to be(false)
    end

    it "returns true when a removed dependency no longer applies" do
      allow(client).to receive(:issue_comments)
        .with(project.full_name, issue.github_number)
        .and_return([ OpenStruct.new(body: "No longer depends on #41") ])

      expect(client).not_to receive(:pull_request).with(project.full_name, 41)

      expect(activity.send(:dependencies_resolved?, client, project, issue)).to be(true)
    end

    it "returns false for cross-repo dependencies" do
      cross_repo_issue = Data.define(:body, :github_number).new(
        body: "Depends on other/repo#41",
        github_number: 42
      )

      expect(activity.send(:dependencies_resolved?, client, project, cross_repo_issue)).to be(false)
    end

    it "treats same-repo fully-qualified dependencies as local merge checks" do
      same_repo_issue = Data.define(:body, :github_number).new(
        body: "Depends on acme/widgets#41",
        github_number: 42
      )

      allow(client).to receive(:pull_request)
        .with(project.full_name, 41)
        .and_return(OpenStruct.new(number: 41, merged: true, merged_at: Time.current))

      expect(activity.send(:dependencies_resolved?, client, project, same_repo_issue)).to be(true)
    end

    it "returns true when all same-repo dependency PRs are merged" do
      allow(client).to receive(:pull_request)
        .with(project.full_name, 41)
        .and_return(OpenStruct.new(number: 41, merged: true, merged_at: Time.current))

      expect(activity.send(:dependencies_resolved?, client, project, issue)).to be(true)
    end

    it "accepts hash-shaped GitHub payloads for comments and PRs" do
      allow(client).to receive(:issue_comments)
        .with(project.full_name, issue.github_number)
        .and_return([ { "body" => "Depends on #41" } ])
      allow(client).to receive(:pull_request)
        .with(project.full_name, 41)
        .and_return({ "number" => 41, "merged" => true, "merged_at" => Time.current.iso8601 })

      hash_body_issue = Data.define(:body, :github_number).new(
        body: nil,
        github_number: 42
      )

      expect(activity.send(:dependencies_resolved?, client, project, hash_body_issue)).to be(true)
    end

    it "ignores nil comment collections and body-less comment payloads" do
      allow(client).to receive(:issue_comments)
        .with(project.full_name, issue.github_number)
        .and_return([ nil, OpenStruct.new(body: nil) ])
      allow(client).to receive(:pull_request)
        .with(project.full_name, 41)
        .and_return(OpenStruct.new(number: 41, merged: true, merged_at: Time.current))

      expect(activity.send(:dependencies_resolved?, client, project, issue)).to be(true)
    end
  end
end
