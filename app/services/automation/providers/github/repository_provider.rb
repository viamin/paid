# frozen_string_literal: true

module Automation
  module Providers
    module Github
      # GitHub-backed implementation of
      # {Automation::Providers::RepositoryProvider}. Wraps {::GithubClient}
      # calls and normalizes the Octokit/Sawyer objects returned by the
      # underlying REST/GraphQL endpoints into the provider-neutral
      # {Automation::Providers::Data} types.
      #
      # This adapter is the reference implementation the other capability
      # adapters (work-item, review) mirror; future providers (GitLab,
      # Bitbucket) should preserve the same public surface.
      class RepositoryProvider < BaseAdapter
        include Automation::Providers::RepositoryProvider

        PROVIDER_ERROR = Automation::Providers::RepositoryProvider::ProviderError

        PR_STATE_MAP = {
          "open" => :open,
          "closed" => :closed
        }.freeze

        CHECK_STATUS_MAP = {
          "queued" => :queued,
          "in_progress" => :in_progress,
          "completed" => :completed
        }.freeze

        CHECK_CONCLUSION_MAP = {
          "success" => :success,
          "failure" => :failure,
          "neutral" => :neutral,
          "cancelled" => :cancelled,
          "skipped" => :skipped,
          "timed_out" => :timed_out,
          "action_required" => :action_required,
          "stale" => :stale
        }.freeze

        MERGE_METHODS = %i[squash merge rebase].freeze

        def fetch_pull_request(repo:, number:)
          pr = with_errors { client.pull_request(repo, number) }
          build_pull_request(pr)
        end

        def list_pull_requests(repo:, state: :open, head: nil, base: nil)
          options = { state: state.to_s }
          options[:head] = head if head
          options[:base] = base if base

          prs = with_errors { client.pull_requests(repo, **options) }
          Array(prs).map { |pr| build_pull_request(pr) }
        end

        def fetch_pull_request_files(repo:, number:)
          with_errors { client.pull_request_files(repo, number) }
        end

        def fetch_check_runs(repo:, ref:)
          runs = with_errors { client.check_runs_for_ref(repo, ref) }
          Array(runs).map { |run| build_check_run(run) }
        end

        def add_labels(repo:, number:, labels:)
          names = Array(labels).map(&:to_s).reject(&:empty?)
          return if names.empty?

          with_errors { client.add_labels_to_issue(repo, number, names) }
          nil
        end

        def remove_label(repo:, number:, label:)
          client.remove_label_from_issue(repo, number, label)
          nil
        rescue ::GithubClient::NotFoundError
          # Removing an absent label returns 404 from GitHub; treat as
          # idempotent rather than propagating a ProviderError.
          nil
        rescue ::GithubClient::Error => e
          raise PROVIDER_ERROR, e.message
        end

        def add_comment(repo:, number:, body:)
          comment = with_errors { client.add_comment(repo, number, body.to_s) }
          build_comment(comment)
        end

        def mark_ready_for_review(repo:, number:)
          with_errors { client.mark_pull_request_ready(repo, number) }
          nil
        end

        def merge_pull_request(repo:, number:, method:, commit_title: nil, commit_message: nil)
          unless MERGE_METHODS.include?(method.to_sym)
            raise PROVIDER_ERROR, "Unsupported merge method: #{method.inspect}"
          end

          response = with_errors do
            client.merge_pull_request(
              repo,
              number,
              merge_method: method.to_s,
              commit_title: commit_title,
              commit_message: commit_message
            )
          end

          build_merge_result(response)
        end

        private

        def build_pull_request(pr)
          raw_state = pr_field(pr, :state)
          merged_at = parse_time(pr_field(pr, :merged_at))

          Data::PullRequest.new(
            number: pr_field(pr, :number),
            title: pr_field(pr, :title).to_s,
            body: pr_field(pr, :body),
            state: PR_STATE_MAP.fetch(raw_state.to_s, :closed),
            draft: pr_field(pr, :draft) == true,
            merged: pr_field(pr, :merged) == true || merged_at.present?,
            mergeable: pr_field(pr, :mergeable),
            head_sha: pr_sub_field(pr, :head, :sha).to_s,
            head_ref: pr_sub_field(pr, :head, :ref).to_s,
            base_ref: pr_sub_field(pr, :base, :ref).to_s,
            author_login: normalize_login(pr_sub_field(pr, :user, :login)),
            labels: extract_labels(pr_field(pr, :labels)),
            created_at: parse_time(pr_field(pr, :created_at)),
            updated_at: parse_time(pr_field(pr, :updated_at)),
            merged_at: merged_at,
            url: pr_field(pr, :html_url),
            raw_state: raw_state&.to_s
          )
        end

        def build_check_run(run)
          raw_status = run_field(run, :status).to_s
          raw_conclusion = run_field(run, :conclusion)

          Data::CheckRun.new(
            name: run_field(run, :name).to_s,
            status: CHECK_STATUS_MAP[raw_status] || :completed,
            conclusion: raw_conclusion ? CHECK_CONCLUSION_MAP[raw_conclusion.to_s] : nil,
            url: run_field(run, :html_url) || run_field(run, :details_url)
          )
        end

        def build_comment(comment)
          Data::Comment.new(
            id: comment_field(comment, :id),
            author_login: normalize_login(comment_sub_field(comment, :user, :login)),
            body: comment_field(comment, :body).to_s,
            created_at: parse_time(comment_field(comment, :created_at)),
            updated_at: parse_time(comment_field(comment, :updated_at)),
            url: comment_field(comment, :html_url)
          )
        end

        def build_merge_result(response)
          merged = bool_field(response, :merged)
          Data::MergeResult.new(
            merged: merged.nil? ? true : merged,
            sha: response_field(response, :sha),
            message: response_field(response, :message)
          )
        end

        # --- field accessors --------------------------------------------------
        # Accept either a Sawyer::Resource (Octokit's default) or a plain Hash
        # with symbol/string keys so adapters stay usable in unit tests that
        # stub the client with hashes.

        def pr_field(pr, key)
          read_field(pr, key)
        end

        def pr_sub_field(pr, *keys)
          keys.reduce(pr) { |acc, key| acc && read_field(acc, key) }
        end

        def run_field(run, key)
          read_field(run, key)
        end

        def comment_field(comment, key)
          read_field(comment, key)
        end

        def comment_sub_field(comment, *keys)
          keys.reduce(comment) { |acc, key| acc && read_field(acc, key) }
        end

        def response_field(response, key)
          read_field(response, key)
        end

        def bool_field(source, key)
          value = read_field(source, key)
          return value if value == true || value == false

          nil
        end

        def read_field(source, key)
          return nil if source.nil?

          if source.respond_to?(key)
            source.public_send(key)
          elsif source.respond_to?(:[])
            source[key] || source[key.to_s]
          end
        end
      end
    end
  end
end
