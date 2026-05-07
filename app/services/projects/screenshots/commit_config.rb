# frozen_string_literal: true

module Projects
  module Screenshots
    class CommitConfig
      Result = Struct.new(:pull_request_url, keyword_init: true)

      attr_reader :project, :config_path, :content

      def initialize(project:, config_path:, content:)
        @project = project
        @config_path = config_path
        @content = content
      end

      def self.call(...)
        new(...).call
      end

      def call
        repo = project.full_name
        branch = "paid/screenshots-config-#{project.id}-#{Time.current.utc.strftime('%Y%m%d%H%M%S')}"
        base_ref = github.ref(repo, "heads/#{project.default_branch}")
        github.create_ref(repo, "refs/heads/#{branch}", base_ref.object.sha)

        existing_file = existing_file_on_default_branch(repo)
        if existing_file
          github.update_contents(
            repo,
            config_path,
            screenshot_commit_message,
            existing_file.sha,
            content,
            branch: branch
          )
        else
          github.create_contents(repo, config_path, screenshot_commit_message, content, branch: branch)
        end

        pull_request = project.github_token.client.create_pull_request(
          repo,
          base: project.default_branch,
          head: branch,
          title: "Add screenshot configuration",
          body: "Adds #{config_path} generated from Paid project screenshot settings."
        )

        Result.new(pull_request_url: pull_request.html_url)
      end

      private

      def github
        project.github_token.client.client
      end

      def existing_file_on_default_branch(repo)
        project.github_token.client.contents(repo, path: config_path, ref: project.default_branch)
      rescue GithubClient::NotFoundError
        nil
      end

      def screenshot_commit_message
        "Add screenshot configuration for Paid"
      end
    end
  end
end
