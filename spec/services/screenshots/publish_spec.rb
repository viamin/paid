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
  let(:homepage_artifacts) do
    {
      route_name: "homepage",
      url: "https://s3.example.com/homepage.png?source=homepage.png"
    }
  end
  let(:dashboard_artifacts) do
    {
      route_name: "dashboard",
      url: "https://s3.example.com/dashboard.png?source=dashboard.png"
    }
  end

  describe "#call" do
    context "with screenshots" do
      let(:screenshot_paths) do
        [
          "/tmp/screenshots/homepage.png",
          "/tmp/screenshots/dashboard.png"
        ]
      end

      let(:previous_screenshots) do
        { "homepage" => { png: "https://s3.example.com/prev-homepage.png" } }
      end

      before do
        allow(storage).to receive_messages(
          upload: nil,
          previous_artifacts: previous_screenshots,
          upload_artifact: nil
        )
        allow(storage).to receive(:upload) do |file_path:, route_name:, **|
          "https://s3.example.com/#{route_name}.png?source=#{File.basename(file_path)}"
        end
        allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return({})
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

      it "delegates trace artifact export to the shared exporter" do
        expect(Screenshots::TraceArtifactExporter).to have_received(:call).with(
          hash_including(
            storage: storage,
            route_name: "homepage",
            frames: [ "/tmp/screenshots/homepage.png" ],
            log_message: "screenshots.publish.export_failed"
          )
        )
        expect(Screenshots::TraceArtifactExporter).to have_received(:call).with(
          hash_including(
            storage: storage,
            route_name: "dashboard",
            frames: [ "/tmp/screenshots/dashboard.png" ],
            log_message: "screenshots.publish.export_failed"
          )
        )
        expect(storage).not_to have_received(:upload_artifact)
      end

      it "posts the uploaded screenshots with previous screenshots to the PR comment" do
        expected_screenshots = [ homepage_artifacts, dashboard_artifacts ]

        expect(Screenshots::PrComment).to have_received(:call).with(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: expected_screenshots,
          previous_screenshots: { "homepage" => "https://s3.example.com/prev-homepage.png" }
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
        allow(storage).to receive(:upload_artifact)
        allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return({})
        allow(Screenshots::PrComment).to receive(:call).and_return(comment)
      end

      it "updates the PR comment without uploading files" do
        service.call

        expect(storage).not_to have_received(:upload)
        expect(storage).not_to have_received(:upload_artifact)
        expect(Screenshots::PrComment).to have_received(:call).with(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: [],
          previous_screenshots: {}
        )
      end
    end

    context "without screenshots and without an injected storage client" do
      subject(:service) do
        described_class.new(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshot_paths: []
        )
      end

      before do
        allow(Screenshots::Storage).to receive(:new).and_raise(ArgumentError, "unexpected storage init")
        allow(Screenshots::PrComment).to receive(:call).and_return(comment)
      end

      it "does not initialize storage for comment-only updates" do
        expect { service.call }.not_to raise_error
        expect(Screenshots::Storage).not_to have_received(:new)
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

    context "when the shared exporter returns no artifacts" do
      let(:screenshot_paths) { [ "/tmp/screenshots/homepage.png" ] }

      before do
        allow(storage).to receive_messages(
          upload: "https://s3.example.com/homepage.png",
          previous_artifacts: {}
        )
        allow(Screenshots::TraceArtifactExporter).to receive(:call).and_return({})
        allow(Screenshots::PrComment).to receive(:call).and_return(comment)
      end

      it "falls back to static PNG publishing" do
        service.call

        expect(Screenshots::PrComment).to have_received(:call).with(
          hash_including(
            screenshots: [ { route_name: "homepage", url: "https://s3.example.com/homepage.png" } ]
          )
        )
      end
    end
  end
end
