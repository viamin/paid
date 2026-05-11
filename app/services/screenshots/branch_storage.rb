# frozen_string_literal: true

require "tmpdir"
require "open3"

module Screenshots
  class BranchStorage
    BRANCH_NAME = "screenshots"
    MAX_PUSH_ATTEMPTS = 3

    class PushError < StandardError; end

    def initialize(repo:, github_token:)
      @repo = repo
      @github_token = github_token
    end

    def self.configured?
      token.present?
    end

    def self.token
      ENV["SCREENSHOTS_GITHUB_TOKEN"].presence || ENV["GITHUB_TOKEN"].presence
    end

    def upload_all(screenshot_paths:, pr_number:, commit_sha:)
      short_sha = commit_sha[0, 8]
      branch_dir = "screenshots/#{pr_number}/#{short_sha}"

      Dir.mktmpdir("screenshots-branch-push") do |git_dir|
        setup_repo(git_dir)

        if branch_exists?
          git(git_dir, "fetch", "--depth=1", "origin", BRANCH_NAME)
          git(git_dir, "checkout", BRANCH_NAME)
        else
          create_orphan_branch(git_dir)
        end

        FileUtils.mkdir_p(File.join(git_dir, branch_dir))
        screenshot_paths.each { |path| FileUtils.cp(path, File.join(git_dir, branch_dir)) }

        git(git_dir, "add", branch_dir)

        if nothing_staged?(git_dir)
          return build_urls(branch_dir, screenshot_paths)
        end

        git(git_dir, "commit", "-m", "screenshots: PR ##{pr_number} @ #{short_sha}")
        push_with_retry(git_dir, branch_dir, screenshot_paths, pr_number, short_sha)
      end
    end

    def previous_screenshots(pr_number:, exclude_sha:, github_client:)
      entries = github_client.contents(@repo, path: "screenshots/#{pr_number}", ref: BRANCH_NAME)
      sha_dirs = Array(entries).select { |e| e.type == "dir" }.map(&:name)
      sha_dirs.reject! { |sha| sha == exclude_sha[0, 8] }
      return {} if sha_dirs.empty?

      latest_sha = latest_by_commit_date(sha_dirs, github_client)
      return {} unless latest_sha

      files = github_client.contents(@repo, path: "screenshots/#{pr_number}/#{latest_sha}", ref: BRANCH_NAME)
      Array(files).each_with_object({}) do |file, result|
        next unless file.name.end_with?(".png")

        route_name = File.basename(file.name, ".png")
        result[route_name] = raw_url("screenshots/#{pr_number}/#{latest_sha}", route_name)
      end
    rescue GithubClient::NotFoundError, GithubClient::Error
      {}
    end

    def delete_pr_screenshots(pr_number:)
      Dir.mktmpdir("screenshots-cleanup") do |git_dir|
        setup_repo(git_dir)

        return unless branch_exists?

        git(git_dir, "fetch", "--depth=1", "origin", BRANCH_NAME)
        git(git_dir, "checkout", BRANCH_NAME)

        pr_dir = File.join(git_dir, "screenshots", pr_number.to_s)
        return unless File.directory?(pr_dir)

        FileUtils.rm_rf(pr_dir)
        git(git_dir, "add", "screenshots")
        return if nothing_staged?(git_dir)

        git(git_dir, "commit", "-m", "cleanup: remove screenshots for PR ##{pr_number}")
        git(git_dir, "push", "origin", BRANCH_NAME)
      end
    end

    private

    def raw_url(branch_dir, route_name)
      "https://raw.githubusercontent.com/#{@repo}/refs/heads/#{BRANCH_NAME}/#{branch_dir}/#{route_name}.png"
    end

    def build_urls(branch_dir, screenshot_paths)
      screenshot_paths.map do |path|
        route_name = File.basename(path, ".png")
        { route_name: route_name, url: raw_url(branch_dir, route_name) }
      end
    end

    def setup_repo(git_dir)
      git(git_dir, "init")
      git(git_dir, "remote", "add", "origin", remote_url)
      git(git_dir, "config", "user.name", "github-actions[bot]")
      git(git_dir, "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    end

    def create_orphan_branch(git_dir)
      git(git_dir, "checkout", "--orphan", BRANCH_NAME)

      readme_path = File.join(git_dir, "README.md")
      File.write(readme_path, <<~MD)
        # Screenshots Branch
        This branch stores PR screenshot images for inline display in PR comments.
        Do not merge this branch into main.
      MD
      git(git_dir, "add", "README.md")
      git(git_dir, "commit", "-m", "chore: initialize screenshots branch")
    end

    def remote_url
      "https://x-access-token:#{@github_token}@github.com/#{@repo}.git"
    end

    def branch_exists?
      system(
        "git", "ls-remote", "--exit-code", remote_url, "refs/heads/#{BRANCH_NAME}",
        out: File::NULL, err: File::NULL
      )
    end

    def nothing_staged?(git_dir)
      system("git", "diff", "--cached", "--quiet", chdir: git_dir, out: File::NULL, err: File::NULL)
    end

    def latest_by_commit_date(sha_dirs, github_client)
      with_dates = sha_dirs.filter_map do |sha|
        c = github_client.commit(@repo, sha)
        date = c&.commit&.committer&.date
        next unless date

        [ sha, date ]
      rescue GithubClient::Error
        nil
      end

      with_dates.max_by { |_, date| date }&.first || sha_dirs.last
    end

    def push_with_retry(git_dir, branch_dir, screenshot_paths, pr_number, short_sha)
      MAX_PUSH_ATTEMPTS.times do |attempt|
        begin
          git(git_dir, "push", "origin", BRANCH_NAME)
          return build_urls(branch_dir, screenshot_paths)
        rescue PushError
          raise if attempt >= MAX_PUSH_ATTEMPTS - 1

          system("git", "fetch", "--depth=1", "origin", BRANCH_NAME, chdir: git_dir, out: File::NULL, err: File::NULL)
          git(git_dir, "reset", "--hard", "origin/#{BRANCH_NAME}")

          FileUtils.mkdir_p(File.join(git_dir, branch_dir))
          screenshot_paths.each { |path| FileUtils.cp(path, File.join(git_dir, branch_dir)) }
          git(git_dir, "add", branch_dir)
          git(git_dir, "commit", "-m", "screenshots: PR ##{pr_number} @ #{short_sha}") unless nothing_staged?(git_dir)
        end
      end
    end

    def git(dir, *args)
      _stdout, stderr, status = Open3.capture3("git", *args, chdir: dir)
      return if status.success?

      redacted = stderr.gsub(@github_token, "***")
      raise PushError, "git #{args.join(" ")} failed: #{redacted}"
    end
  end
end
