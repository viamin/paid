# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::PrComment do
  subject(:service) do
    described_class.new(
      github_client: github_client,
      repo: repo,
      pr_number: pr_number,
      commit_sha: commit_sha,
      screenshots: screenshots
    )
  end

  let(:github_client) { instance_double(GithubClient) }
  let(:repo) { "acme/web" }
  let(:pr_number) { 42 }
  let(:commit_sha) { "abc1234def5678" }
  let(:screenshots) do
    [
      { route_name: "dashboard", url: "https://s3.example.com/dashboard.png" },
      { route_name: "homepage", url: "https://s3.example.com/homepage.png" }
    ]
  end

  describe "#build_comment_body" do
    it "includes the marker comment" do
      body = service.build_comment_body

      expect(body).to start_with(described_class::MARKER)
    end

    it "includes the short commit SHA" do
      body = service.build_comment_body

      expect(body).to include("`abc1234`")
    end

    it "renders a markdown table with sorted screenshots" do
      body = service.build_comment_body

      expect(body).to include("| Dashboard | ![dashboard](https://s3.example.com/dashboard.png) |")
      expect(body).to include("| Homepage | ![homepage](https://s3.example.com/homepage.png) |")
    end

    it "humanizes route names with underscores" do
      screenshots = [ { route_name: "project_show", url: "https://s3.example.com/project_show.png" } ]
      service = described_class.new(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: screenshots
      )

      body = service.build_comment_body

      expect(body).to include("| Project Show |")
    end

    context "with previous screenshots for before/after comparison" do
      let(:previous_screenshots) do
        {
          "dashboard" => "https://s3.example.com/prev-dashboard.png",
          "homepage" => "https://s3.example.com/prev-homepage.png"
        }
      end

      it "renders a before/after table when previous screenshots exist" do
        service = described_class.new(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: screenshots,
          previous_screenshots: previous_screenshots
        )

        body = service.build_comment_body

        expect(body).to include("| Page | Before | After |")
        expect(body).to include("![before-dashboard](https://s3.example.com/prev-dashboard.png)")
        expect(body).to include("![dashboard](https://s3.example.com/dashboard.png)")
      end

      it "shows 'New page' for routes without a previous screenshot" do
        service = described_class.new(
          github_client: github_client,
          repo: repo,
          pr_number: pr_number,
          commit_sha: commit_sha,
          screenshots: [ { route_name: "settings", url: "https://s3.example.com/settings.png" } ],
          previous_screenshots: { "other_route" => "https://s3.example.com/prev-other.png" }
        )

        body = service.build_comment_body

        expect(body).to include("| Page | Before | After |")
        expect(body).to include("_New page_")
        expect(body).to include("![settings](https://s3.example.com/settings.png)")
      end
    end

    it "handles empty screenshots" do
      service = described_class.new(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: []
      )

      body = service.build_comment_body

      expect(body).to include("No screenshots captured")
      expect(body).not_to include("| Page |")
    end

    it "renders artifact fallback instructions when inline uploads are unavailable" do
      service = described_class.new(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        artifact_name: "pr-screenshots"
      )

      body = service.build_comment_body

      expect(body).to include("inline screenshot upload is unavailable")
      expect(body).to include("Download the `pr-screenshots` workflow artifact")
      expect(body).not_to include("| Page |")
    end

    it "renders a stale notice when the PR no longer has UI changes" do
      service = described_class.new(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        status: "no_ui_changes"
      )

      body = service.build_comment_body

      expect(body).to include("no longer contains UI-facing changes")
      expect(body).to include("`abc1234`")
    end

    it "renders a failure notice when screenshot capture fails" do
      service = described_class.new(
        github_client: github_client,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        screenshots: [],
        status: "capture_failed"
      )

      body = service.build_comment_body

      expect(body).to include("screenshot capture failed")
      expect(body).to include("stale and should not be used for review")
    end
  end

  describe "#call" do
    context "when no existing comment exists" do
      before do
        allow(github_client).to receive(:recent_issue_comments).and_return([])
      end

      it "creates a new comment" do
        created_comment = Struct.new(:id, :body).new(id: 1, body: "created")
        allow(github_client).to receive(:add_comment).and_return(created_comment)

        result = service.call

        expect(github_client).to have_received(:add_comment).with(
          repo,
          pr_number,
          a_string_starting_with(described_class::MARKER)
        )
        expect(result).to eq(created_comment)
      end
    end

    context "when an existing comment with marker exists" do
      let(:existing_comment) do
        Struct.new(:id, :body).new(id: 999, body: "#{described_class::MARKER}\nold content")
      end

      before do
        allow(github_client).to receive(:recent_issue_comments).and_return(
          [
            Struct.new(:id, :body).new(id: 1, body: "unrelated comment"),
            existing_comment
          ]
        )
      end

      it "updates the existing comment" do
        updated_comment = Struct.new(:id, :body).new(id: 999, body: "updated")
        allow(github_client).to receive(:update_comment).and_return(updated_comment)

        result = service.call

        expect(github_client).to have_received(:update_comment).with(
          repo,
          999,
          a_string_starting_with(described_class::MARKER)
        )
        expect(github_client).not_to have_received(:add_comment) if github_client.respond_to?(:add_comment)
        expect(result).to eq(updated_comment)
      end
    end

    context "when the marker is not in recent comments" do
      let(:older_page_url) { "https://api.github.com/repos/acme/web/issues/42/comments?page=1" }
      let(:recent_comments) do
        page_url = older_page_url
        [].tap do |comments|
          comments.define_singleton_method(:next_older_page_url) { page_url }
        end
      end
      let(:existing_comment) do
        Struct.new(:id, :body).new(id: 999, body: "#{described_class::MARKER}\nold content")
      end

      before do
        allow(github_client).to receive(:recent_issue_comments).and_return(recent_comments)
        allow(github_client).to receive(:fetch_issue_comment_page).with(older_page_url).and_return([ existing_comment ])
      end

      it "falls back to older pages before creating a new comment" do
        updated_comment = Struct.new(:id, :body).new(id: 999, body: "updated")
        allow(github_client).to receive(:update_comment).and_return(updated_comment)

        result = service.call

        expect(github_client).to have_received(:recent_issue_comments).with(repo, pr_number)
        expect(github_client).to have_received(:fetch_issue_comment_page).with(older_page_url)
        expect(github_client).to have_received(:update_comment).with(
          repo,
          999,
          a_string_starting_with(described_class::MARKER)
        )
        expect(result).to eq(updated_comment)
      end
    end
  end
end
