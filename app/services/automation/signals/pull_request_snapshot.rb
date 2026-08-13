# frozen_string_literal: true

module Automation
  module Signals
    class PullRequestSnapshot
      HeadRepo = ::Data.define(:fork)
      Head = ::Data.define(:sha, :ref, :repo)
      User = ::Data.define(:login)

      attr_reader :number, :title, :body, :state, :draft, :merged, :mergeable,
        :head_sha, :head_ref, :base_ref, :author_login, :labels, :created_at,
        :updated_at, :merged_at, :url, :raw_state, :head_repo_fork

      def self.from_provider(pr_data)
        new(
          number: pr_data.number,
          title: pr_data.title,
          body: pr_data.body,
          state: pr_data.state,
          draft: pr_data.draft,
          merged: pr_data.merged,
          mergeable: pr_data.mergeable,
          head_sha: pr_data.head_sha,
          head_ref: pr_data.head_ref,
          base_ref: pr_data.base_ref,
          author_login: pr_data.author_login,
          labels: pr_data.labels,
          created_at: pr_data.created_at,
          updated_at: pr_data.updated_at,
          merged_at: pr_data.merged_at,
          url: pr_data.url,
          raw_state: pr_data.raw_state,
          head_repo_fork: pr_data.head_repo_fork
        )
      end

      def initialize(number:, title:, body:, state:, draft:, merged:, mergeable:,
        head_sha:, head_ref:, base_ref:, author_login:, labels:, created_at:,
        updated_at:, merged_at:, url:, raw_state:, head_repo_fork:)
        @number = number
        @title = title
        @body = body
        @state = state
        @draft = draft
        @merged = merged
        @mergeable = mergeable
        @head_sha = head_sha
        @head_ref = head_ref
        @base_ref = base_ref
        @author_login = author_login
        @labels = labels
        @created_at = created_at
        @updated_at = updated_at
        @merged_at = merged_at
        @url = url
        @raw_state = raw_state
        @head_repo_fork = head_repo_fork
      end

      def [](key)
        public_send(key) if respond_to?(key)
      end

      def head
        Head.new(sha: head_sha, ref: head_ref, repo: HeadRepo.new(fork: head_repo_fork))
      end

      def user
        User.new(login: author_login)
      end
    end
  end
end
