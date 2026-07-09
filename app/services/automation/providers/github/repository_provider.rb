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
          raw_state = read_field(pr, :state)
          merged_at = parse_time(read_field(pr, :merged_at))

          Data::PullRequest.new(
            number: read_field(pr, :number),
            title: read_field(pr, :title).to_s,
            body: read_field(pr, :body),
            state: PR_STATE_MAP.fetch(raw_state.to_s, :closed),
            draft: read_field(pr, :draft) == true,
            merged: read_field(pr, :merged) == true || merged_at.present?,
            mergeable: read_field(pr, :mergeable),
            head_sha: read_sub_field(pr, :head, :sha).to_s,
            head_ref: read_sub_field(pr, :head, :ref).to_s,
            base_ref: read_sub_field(pr, :base, :ref).to_s,
            author_login: normalize_login(read_sub_field(pr, :user, :login)),
            labels: extract_labels(read_field(pr, :labels)),
            created_at: parse_time(read_field(pr, :created_at)),
            updated_at: parse_time(read_field(pr, :updated_at)),
            merged_at: merged_at,
            url: read_field(pr, :html_url),
            raw_state: raw_state&.to_s,
            head_repo_fork: head_repo_fork(pr)
          )
        end

        # Reads the head repository's fork flag. GitHub reports this as
        # +head.repo.fork+ on the pull request payload; it drives the
        # ci_action gating that a forked head cannot fulfill. Returns
        # +nil+ when the payload omits the flag (e.g. test doubles) so
        # callers can distinguish "not a fork" from "unknown".
        def head_repo_fork(pr)
          fork = read_sub_field(pr, :head, :repo, :fork)
          fork.nil? ? nil : (fork == true)
        end

        def build_check_run(run)
          raw_status = read_field(run, :status).to_s
          raw_conclusion = read_field(run, :conclusion)

          Data::CheckRun.new(
            name: read_field(run, :name).to_s,
            # Default to :queued for unknown statuses so consumers gating on
            # "all checks finished?" keep waiting instead of advancing while
            # the check is still running. GitHub has added new status values
            # over time (e.g. "waiting", "pending"); a :completed fallback
            # would let auto-merge / auto-review races slip through.
            status: CHECK_STATUS_MAP[raw_status] || :queued,
            conclusion: normalize_conclusion(raw_conclusion),
            url: read_field(run, :html_url) || read_field(run, :details_url)
          )
        end

        # Map GitHub's +conclusion+ string to the normalized symbol.
        #
        # +nil+ is preserved because {Data::CheckRun#conclusion} documents it
        # as "Nil while the check is still running". An unknown non-nil
        # conclusion (e.g. a forward-compat value GitHub adds later) must NOT
        # collapse to +nil+, since that would be indistinguishable from
        # "still running" — instead we conservatively report
        # +:action_required+ and log the gap so the mapping can be updated.
        def normalize_conclusion(raw_conclusion)
          return nil if raw_conclusion.nil?

          key = raw_conclusion.to_s
          mapped = CHECK_CONCLUSION_MAP[key]
          return mapped if mapped

          Rails.logger.warn(
            message: "automation.github.unknown_check_conclusion",
            component: "automation_provider",
            raw_conclusion: key
          )
          :action_required
        end

        def build_comment(comment)
          Data::Comment.new(
            id: read_field(comment, :id),
            author_login: normalize_login(read_sub_field(comment, :user, :login)),
            body: read_field(comment, :body).to_s,
            created_at: parse_time(read_field(comment, :created_at)),
            updated_at: parse_time(read_field(comment, :updated_at)),
            url: read_field(comment, :html_url)
          )
        end

        def build_merge_result(response)
          # GitHub's merge API returns +merged: true+ on 2xx and raises on
          # non-2xx, so defaulting to +false+ when the field is missing
          # prevents a malformed response (or a test mock that forgets the
          # field) from being reported as a successful merge.
          Data::MergeResult.new(
            merged: read_field(response, :merged) == true,
            sha: read_field(response, :sha),
            message: read_field(response, :message)
          )
        end
      end
    end
  end
end
