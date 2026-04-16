# frozen_string_literal: true

module Automation
  module Providers
    module Github
      # GitHub-backed implementation of
      # {Automation::Providers::WorkItemProvider}.
      #
      # GitHub models issues and pull requests through a shared API; this
      # adapter surfaces both through {Data::Issue}. The +pull_request_number+
      # field is populated when the fetched item is also a pull request,
      # letting policy code distinguish issue-only items from PR-backed ones
      # without re-fetching.
      #
      # Structured dependency edges are intentionally left empty: GitHub's
      # native dependency graph is not exposed through the REST API used by
      # this adapter. Paid's {Issues::ParseDependencies} text parser
      # continues to be the source of truth for cross-issue blockers.
      class WorkItemProvider < BaseAdapter
        include Automation::Providers::WorkItemProvider

        PROVIDER_ERROR = Automation::Providers::WorkItemProvider::ProviderError

        ISSUE_STATE_MAP = {
          "open" => :open,
          "closed" => :closed
        }.freeze

        CLOSED_STATES = %i[closed].freeze

        def fetch_issue(repo:, number:)
          issue = with_errors { client.issue(repo, number) }
          build_issue(issue)
        end

        def list_issues(repo:, state: :open, labels: nil, assignees: nil)
          options = {}
          options[:state] = state.to_s if state
          options[:assignee] = Array(assignees).first if assignees.present?

          issues = with_errors { client.issues(repo, labels: labels, **options) }
          Array(issues).map { |issue| build_issue(issue) }
        end

        def fetch_issue_comments(repo:, number:)
          comments = with_errors { client.issue_comments(repo, number) }
          Array(comments).map { |comment| build_comment(comment) }
        end

        def fetch_issue_timeline(repo:, number:)
          events = with_errors { client.issue_events(repo, number) }
          Array(events).map { |event| build_timeline_event(event) }
        end

        def create_issue(repo:, title:, body: "", labels: [])
          names = Array(labels).map(&:to_s).reject(&:empty?)
          created = with_errors do
            client.create_issue(repo, title: title.to_s, body: body.to_s, labels: names)
          end
          build_issue(created)
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

        def transition_state(repo:, number:, state:, reason: nil)
          symbolic = state.to_sym
          unless Data::Issue::STATES.include?(symbolic)
            raise PROVIDER_ERROR, "Unsupported issue state: #{state.inspect}"
          end

          options = { state: symbolic.to_s }
          options[:state_reason] = reason if reason && CLOSED_STATES.include?(symbolic)

          updated = with_errors { client.update_issue(repo, number, **options) }
          build_issue(updated)
        end

        private

        def build_issue(issue)
          raw_state = read_field(issue, :state)
          pr_payload = read_field(issue, :pull_request)

          Data::Issue.new(
            number: read_field(issue, :number),
            title: read_field(issue, :title).to_s,
            body: read_field(issue, :body),
            state: ISSUE_STATE_MAP.fetch(raw_state.to_s, :closed),
            raw_state: raw_state&.to_s,
            author_login: normalize_login(read_sub_field(issue, :user, :login)),
            assignee_logins: extract_assignee_logins(issue),
            labels: extract_labels(read_field(issue, :labels)),
            dependencies: [],
            created_at: parse_time(read_field(issue, :created_at)),
            updated_at: parse_time(read_field(issue, :updated_at)),
            closed_at: parse_time(read_field(issue, :closed_at)),
            url: read_field(issue, :html_url),
            pull_request_number: pr_payload.present? ? read_field(issue, :number) : nil
          )
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

        def build_timeline_event(event)
          raw = event.respond_to?(:to_hash) ? event.to_hash : (event.is_a?(Hash) ? event : {})

          Data::TimelineEvent.new(
            event: map_timeline_event(read_field(event, :event)),
            actor_login: normalize_login(read_sub_field(event, :actor, :login)),
            label_name: read_sub_field(event, :label, :name),
            created_at: parse_time(read_field(event, :created_at)),
            raw: raw
          )
        end

        def map_timeline_event(name)
          symbolic = name.to_s.to_sym
          return symbolic if Data::TimelineEvent::EVENTS.include?(symbolic)

          :other
        end

        def extract_assignee_logins(issue)
          assignees = read_field(issue, :assignees)
          if assignees.present?
            Array(assignees).filter_map { |a| normalize_login(read_field(a, :login)) }
          else
            login = normalize_login(read_sub_field(issue, :assignee, :login))
            login ? [ login ] : []
          end
        end

        def read_sub_field(source, *keys)
          keys.reduce(source) { |acc, key| acc && read_field(acc, key) }
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
