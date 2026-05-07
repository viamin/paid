# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::Publish do
  subject(:service) do
    described_class.new(
      github_client: github_client,
      repo: repo,
      pr_number: pr_number,
      commit_sha: commit_sha,
      screenshot_paths: screenshot_paths,
      storage: storage
    )
  end

  let(:github_client) { instance_double(GithubClient) }
  let(:storage) { instance_double(Screenshots::Storage) }
  let(:repo) { "acme/web" }
  let(:pr_number) { 42 }
  let(:commit_sha) { "abc1234def5678" }
  let(:comment) { Struct.new(:id).new(1) }

  describe "#call" do
    context "with screenshots" do
      let(:screenshot_paths) do
        [
          "/tmp/screenshots/homepage.png",
          "/tmp/screenshots/dashboard.png"
        ]
      end

      before do
        allow(storage).to receive(:upload) do |file_path:, route_name:, **|
          "https://s3.example.com/#{route_name}.png?source=#{File.basename(file_path)}"
        end
        allow(Screenshots::PrComment).to receive(:call).and_return(comment)
        service.call
      end

      it "uploads each screenshot" do
        expect(storage).to have_received(:upload).with(
          file_path: "/tmp/screenshots/homepage.png",
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: commit_sha,
          route_name: "homepage"
        )
        expect(storage).to have_received(:upload).with(
          file_path: "/tmp/screenshots/dashboard.png",
          org: "acme",
          repo: "web",
          pr_number: 42,
          commit_sha: commit_sha,
          route_name: "dashboard"
        )
      end

      it "posts the uploaded screenshots to the PR comment" do
        expect(Screenshots::PrComment).to have_received(:call).with(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: [
            { route_name: "homepage", url: "https://s3.example.com/homepage.png?source=homepage.png" },
            { route_name: "dashboard", url: "https://s3.example.com/dashboard.png?source=dashboard.png" }
          ]
        )
      end

      it "returns the created or updated comment" do
        expect(service.call).to eq(comment)
      end
    end

    context "without screenshots" do
      let(:screenshot_paths) { [] }

      before do
        allow(storage).to receive(:upload)
        allow(Screenshots::PrComment).to receive(:call).and_return(comment)
      end

      it "updates the PR comment without uploading files" do
        service.call

        expect(storage).not_to have_received(:upload)
        expect(Screenshots::PrComment).to have_received(:call).with(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: []
        )
      end
    end

    context "when the repo is invalid" do
      let(:repo) { "acme" }
      let(:screenshot_paths) { [ "/tmp/screenshots/homepage.png" ] }

      it "raises a descriptive error" do
        expect { service.call }
          .to raise_error(Screenshots::Publish::PublishError, /owner\/name/)
      end
    end
  end
end
