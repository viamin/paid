# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::BranchStorage, :no_db do
  let(:repo) { "acme/web" }
  let(:token) { "ghp_test123" }
  let(:storage) { described_class.new(repo: repo, github_token: token) }

  describe ".configured?" do
    around do |example|
      original = ENV.to_h.slice("GITHUB_TOKEN", "SCREENSHOTS_GITHUB_TOKEN")
      example.run
    ensure
      %w[GITHUB_TOKEN SCREENSHOTS_GITHUB_TOKEN].each do |key|
        original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
      end
    end

    it "returns true when GITHUB_TOKEN is present" do
      ENV["GITHUB_TOKEN"] = "ghp_test"

      expect(described_class.configured?).to be true
    end

    it "returns true when SCREENSHOTS_GITHUB_TOKEN is present" do
      ENV["SCREENSHOTS_GITHUB_TOKEN"] = "ghp_custom"
      ENV.delete("GITHUB_TOKEN")

      expect(described_class.configured?).to be true
    end

    it "prefers SCREENSHOTS_GITHUB_TOKEN over GITHUB_TOKEN" do
      ENV["GITHUB_TOKEN"] = "ghp_default"
      ENV["SCREENSHOTS_GITHUB_TOKEN"] = "ghp_custom"

      expect(described_class.token).to eq("ghp_custom")
    end

    it "returns false when no token is set" do
      ENV.delete("GITHUB_TOKEN")
      ENV.delete("SCREENSHOTS_GITHUB_TOKEN")

      expect(described_class.configured?).to be false
    end
  end

  describe "#upload_all" do
    let(:output_dir) { Dir.mktmpdir }
    let(:screenshot_paths) do
      [
        create_screenshot(output_dir, "dashboard.png"),
        create_screenshot(output_dir, "homepage.png")
      ]
    end

    before do
      allow(storage).to receive_messages(
        setup_repo: nil,
        branch_exists?: true,
        nothing_staged?: false,
        git: nil
      )
    end

    after { FileUtils.rm_rf(output_dir) }

    it "returns URL mappings for each screenshot" do
      result = storage.upload_all(
        screenshot_paths: screenshot_paths,
        pr_number: 42,
        commit_sha: "abc1234def5678"
      )

      expect(result.size).to eq(2)
      expect(result[0][:route_name]).to eq("dashboard")
      expect(result[0][:url]).to include("screenshots/42/abc1234d/dashboard.png")
      expect(result[1][:route_name]).to eq("homepage")
    end

    it "uses an 8-character short SHA in the path" do
      result = storage.upload_all(
        screenshot_paths: screenshot_paths,
        pr_number: 42,
        commit_sha: "abcdef1234567890"
      )

      expect(result[0][:url]).to include("/screenshots/42/abcdef12/")
    end

    it "returns URLs without committing when nothing is staged" do
      allow(storage).to receive(:nothing_staged?).and_return(true)

      result = storage.upload_all(
        screenshot_paths: screenshot_paths,
        pr_number: 42,
        commit_sha: "abc1234def5678"
      )

      expect(result.size).to eq(2)
      expect(result[0][:route_name]).to eq("dashboard")
    end

    context "when branch does not exist" do
      before do
        allow(storage).to receive(:branch_exists?).and_return(false)
        allow(storage).to receive(:create_orphan_branch)
      end

      it "creates an orphan branch" do
        storage.upload_all(
          screenshot_paths: screenshot_paths,
          pr_number: 42,
          commit_sha: "abc1234def5678"
        )

        expect(storage).to have_received(:create_orphan_branch).once
      end
    end

    it "bootstraps the screenshots branch before the first push" do
      bare_repo_dir = Dir.mktmpdir("screenshots-remote")
      system("git", "init", "--bare", bare_repo_dir, exception: true)
      allow(storage).to receive(:setup_repo).and_call_original
      allow(storage).to receive(:branch_exists?).and_call_original
      allow(storage).to receive(:nothing_staged?).and_call_original
      allow(storage).to receive(:git).and_call_original
      allow(storage).to receive(:remote_url).and_return(bare_repo_dir)

      result = storage.upload_all(
        screenshot_paths: screenshot_paths,
        pr_number: 42,
        commit_sha: "abc1234def5678"
      )

      ref_output, = Open3.capture2(
        "git", "ls-remote", "--heads", bare_repo_dir, Screenshots::BranchStorage::BRANCH_NAME
      )

      expect(result.map { |entry| entry[:route_name] }).to contain_exactly("dashboard", "homepage")
      expect(ref_output).to include("refs/heads/screenshots")
    ensure
      FileUtils.rm_rf(bare_repo_dir)
    end
  end

  describe "#previous_screenshots" do
    let(:github_client) { instance_double(GithubClient) }

    before do
      allow(github_client).to receive(:contents).with(repo, path: "screenshots/42", ref: "screenshots").and_return(
        [
          double(type: "dir", name: "old11111"),
          double(type: "dir", name: "abc12345"),
          double(type: "file", name: "README.md")
        ]
      )
      allow(github_client).to receive(:contents).with(repo, path: "screenshots/42/old11111", ref: "screenshots").and_return(
        [
          double(type: "file", name: "dashboard.png"),
          double(type: "file", name: "homepage.png")
        ]
      )
      allow(github_client).to receive(:commit).with(repo, "old11111").and_return(
        build_commit(date: Time.utc(2026, 5, 10))
      )
    end

    it "returns URLs for the latest previous commit by date" do
      result = storage.previous_screenshots(
        pr_number: 42,
        exclude_sha: "abc12345",
        github_client: github_client
      )

      expect(result.keys).to contain_exactly("dashboard", "homepage")
      expect(result["dashboard"]).to include("screenshots/42/old11111/dashboard.png")
    end

    context "with multiple previous SHAs" do
      before do
        allow(github_client).to receive(:contents).with(repo, path: "screenshots/42", ref: "screenshots").and_return(
          [
            double(type: "dir", name: "aaaa_old"),
            double(type: "dir", name: "zzzz_new")
          ]
        )
        allow(github_client).to receive(:contents).with(repo, path: "screenshots/42/zzzz_new", ref: "screenshots").and_return(
          [ double(type: "file", name: "page.png") ]
        )
        allow(github_client).to receive(:commit).with(repo, "aaaa_old").and_return(
          build_commit(date: Time.utc(2026, 5, 9))
        )
        allow(github_client).to receive(:commit).with(repo, "zzzz_new").and_return(
          build_commit(date: Time.utc(2026, 5, 11))
        )
      end

      it "picks the commit with the most recent date" do
        result = storage.previous_screenshots(
          pr_number: 42,
          exclude_sha: "xyz_notexist",
          github_client: github_client
        )

        expect(result["page"]).to include("screenshots/42/zzzz_new/page.png")
      end
    end

    it "returns empty hash when no previous commits exist" do
      allow(github_client).to receive(:contents).with(repo, path: "screenshots/42", ref: "screenshots").and_return(
        [
          double(type: "dir", name: "abc12345")
        ]
      )

      result = storage.previous_screenshots(
        pr_number: 42,
        exclude_sha: "abc12345",
        github_client: github_client
      )

      expect(result).to eq({})
    end

    it "returns empty hash when the branch does not exist" do
      allow(github_client).to receive(:contents).and_raise(GithubClient::NotFoundError)

      result = storage.previous_screenshots(
        pr_number: 42,
        exclude_sha: "abc12345",
        github_client: github_client
      )

      expect(result).to eq({})
    end

    it "falls back to last SHA when commit API fails" do
      allow(github_client).to receive(:contents).with(repo, path: "screenshots/42", ref: "screenshots").and_return(
        [
          double(type: "dir", name: "failed1"),
          double(type: "dir", name: "failed2")
        ]
      )
      allow(github_client).to receive(:contents).with(repo, path: "screenshots/42/failed2", ref: "screenshots").and_return(
        [ double(type: "file", name: "page.png") ]
      )
      allow(github_client).to receive(:commit).and_raise(GithubClient::Error)

      result = storage.previous_screenshots(
        pr_number: 42,
        exclude_sha: "xyz_notexist",
        github_client: github_client
      )

      expect(result["page"]).to include("screenshots/42/failed2/page.png")
    end
  end

  describe "#delete_pr_screenshots" do
    before do
      allow(storage).to receive_messages(
        setup_repo: nil,
        branch_exists?: true,
        nothing_staged?: false,
        git: nil
      )
    end

    it "removes the PR directory from the screenshots branch" do
      expect { storage.delete_pr_screenshots(pr_number: 42) }.not_to raise_error
    end

    it "does nothing when the branch does not exist" do
      allow(storage).to receive(:branch_exists?).and_return(false)

      expect { storage.delete_pr_screenshots(pr_number: 42) }.not_to raise_error
    end
  end

  describe "git error handling" do
    it "raises PushError with redacted token from stderr" do
      allow(Open3).to receive(:capture3).and_return(
        [ "out", "error: remote: Invalid token #{token}", double(success?: false) ]
      )

      expect {
        storage.send(:git, "/tmp/dir", "push", "origin", "screenshots")
      }.to raise_error(Screenshots::BranchStorage::PushError) do |error|
        expect(error.message).to include("***")
        expect(error.message).not_to include(token)
        expect(error.message).to include("git push origin screenshots failed")
      end
    end

    it "returns nil on success" do
      allow(Open3).to receive(:capture3).and_return(
        [ "out", "", double(success?: true) ]
      )

      expect(storage.send(:git, "/tmp/dir", "status")).to be_nil
    end
  end

  private

  def create_screenshot(dir, name)
    path = File.join(dir, name)
    File.write(path, "fake png")
    path
  end

  def build_commit(date:)
    double(
      commit: double(
        committer: double(date: date)
      )
    )
  end
end
