# frozen_string_literal: true

module Automation
  module Providers
    module Github
      # GitHub-backed implementation of
      # {Automation::Providers::ReviewProvider}.
      #
      # GitHub exposes review state through REST for individual reviews and
      # through GraphQL for review threads (line-level conversations). This
      # adapter hides that split behind the normalized {Data} types. Bot
      # reviewers and team reviewers are preserved where the interface
      # accepts them.
      class ReviewProvider < BaseAdapter
        include Automation::Providers::ReviewProvider

        PROVIDER_ERROR = Automation::Providers::ReviewProvider::ProviderError

        REVIEW_STATE_MAP = {
          "APPROVED" => :approved,
          "CHANGES_REQUESTED" => :changes_requested,
          "COMMENTED" => :commented,
          "DISMISSED" => :dismissed,
          "PENDING" => :pending
        }.freeze

        REVIEW_EVENTS = {
          approve: "APPROVE",
          request_changes: "REQUEST_CHANGES",
          comment: "COMMENT"
        }.freeze

        def fetch_reviews(repo:, pr_number:)
          reviews = with_errors { client.pull_request_reviews(repo, pr_number) }
          Array(reviews).map { |review| build_review(review) }
        end

        def fetch_review_threads(repo:, pr_number:)
          threads = with_errors { client.review_threads(repo, pr_number) }
          Array(threads).map { |thread| build_review_thread(thread) }
        end

        def fetch_review_requests(repo:, pr_number:)
          payload = with_errors { client.pull_request_review_requests(repo, pr_number) }
          Data::ReviewRequest.new(
            users: Array(payload[:users]).filter_map { |u| normalize_login(u) },
            teams: Array(payload[:teams]).map(&:to_s)
          )
        end

        def fetch_pending_reviewers(repo:, pr_number:)
          fetch_review_requests(repo: repo, pr_number: pr_number).users
        end

        def request_reviewers(repo:, pr_number:, reviewers:)
          desired = Array(reviewers).filter_map { |r| normalize_login(r) }.uniq
          return [] if desired.empty?

          already_pending = fetch_pending_reviewers(repo: repo, pr_number: pr_number).to_set
          newly_requested = desired.reject { |login| already_pending.include?(login) }
          return [] if newly_requested.empty?

          with_errors do
            client.request_pull_request_review(repo, pr_number, reviewers: newly_requested)
          end

          newly_requested
        end

        def submit_review(repo:, pr_number:, body:, event:)
          api_event = REVIEW_EVENTS[event.to_sym] or
            raise PROVIDER_ERROR, "Unsupported review event: #{event.inspect}"

          response = with_errors do
            client.create_pull_request_review(repo, pr_number, event: api_event, body: body.to_s)
          end

          build_review(response)
        end

        def resolve_review_thread(repo:, pr_number:, thread_id:)
          # thread_id is the GraphQL node id returned by #fetch_review_threads.
          # repo and pr_number are accepted per the interface but unused here
          # because the mutation operates on the opaque node id.
          _ = repo
          _ = pr_number
          with_errors { client.resolve_review_thread(thread_id) }
          nil
        end

        private

        def build_review(review)
          raw_state = read_field(review, :state).to_s
          submitted = parse_time(read_field(review, :submitted_at))
          login = read_field(review, :user_login) || read_sub_field(review, :user, :login)

          Data::Review.new(
            id: read_field(review, :id),
            author_login: normalize_login(login),
            state: REVIEW_STATE_MAP[raw_state] || :commented,
            raw_state: raw_state,
            body: read_field(review, :body).to_s,
            submitted_at: submitted,
            commit_sha: read_field(review, :commit_id) || read_field(review, :commit_sha)
          )
        end

        def build_review_thread(thread)
          raw_comments = Array(read_field(thread, :comments))
          comments = raw_comments.map { |c| build_thread_comment(c) }

          Data::ReviewThread.new(
            id: read_field(thread, :id).to_s,
            resolved: bool_field(thread, :is_resolved) || bool_field(thread, :resolved) || false,
            comments: comments
          )
        end

        def build_thread_comment(comment)
          Data::ReviewThreadComment.new(
            author_login: normalize_login(
              read_field(comment, :author) || read_sub_field(comment, :user, :login)
            ),
            body: read_field(comment, :body).to_s,
            path: read_field(comment, :path),
            line: read_field(comment, :line),
            created_at: parse_time(read_field(comment, :created_at)),
            commit_id: read_field(comment, :commit_id)
          )
        end

        def bool_field(source, key)
          value = read_field(source, key)
          return value if value == true || value == false

          nil
        end
      end
    end
  end
end
