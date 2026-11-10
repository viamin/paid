# frozen_string_literal: true

module IssueTrackers
  module Adapters
    class Linear < Base
      ENDPOINT = "https://api.linear.app/graphql"
      PAGE_SIZE = 50

      class Error < StandardError; end
      class AuthenticationError < Error; end
      class ResponseError < Error; end
      class RateLimitedError < Error
        attr_reader :retry_after

        def initialize(retry_after:)
          @retry_after = retry_after
          super("Linear rate limit reached; retry after #{retry_after} seconds")
        end
      end

      ISSUE_FIELDS = <<~GRAPHQL.freeze
        id identifier title description url priority createdAt updatedAt archivedAt
        state { id name type }
        team { id key name }
        project { id name }
        cycle { id name }
        creator { id name email }
        assignee { id name email }
        labels { nodes { id name } }
      GRAPHQL

      # @spec UNIFIED-WORK-ITEMS-003
      def list_issues(filters: {})
        raise ArgumentError, "Unsupported Linear issue filters: #{filters.keys.join(', ')}" if filters.present?

        issues = []
        cursor = nil
        loop do
          page = execute(<<~GRAPHQL, { first: PAGE_SIZE, after: cursor }).fetch("issues")
            query ListIssues($first: Int!, $after: String) {
              issues(first: $first, after: $after, includeArchived: true, orderBy: updatedAt) {
                nodes { #{ISSUE_FIELDS} }
                pageInfo { hasNextPage endCursor }
              }
            }
          GRAPHQL
          issues.concat(page.fetch("nodes").map { |node| issue_data(node) })
          break unless page.fetch("pageInfo").fetch("hasNextPage")

          next_cursor = page.fetch("pageInfo").fetch("endCursor")
          raise ResponseError, "Linear returned a repeated pagination cursor" if next_cursor.blank? || next_cursor == cursor

          cursor = next_cursor
        end
        issues
      end

      def get_issue(external_id:)
        node = execute(<<~GRAPHQL, { id: external_id }).fetch("issue")
          query GetIssue($id: String!) { issue(id: $id) { #{ISSUE_FIELDS} } }
        GRAPHQL
        issue_data(node) if node
      end

      def add_comment(external_id:, body:)
        return if comments_suppressed?

        payload = execute(<<~GRAPHQL, { input: { issueId: external_id, body: body } }).fetch("commentCreate")
          mutation AddComment($input: CommentCreateInput!) {
            commentCreate(input: $input) { success comment { id } }
          }
        GRAPHQL
        mutation_id!(payload, "comment")
      end

      def update_status(external_id:, status:)
        payload = execute(<<~GRAPHQL, { id: external_id, input: { stateId: status } }).fetch("issueUpdate")
          mutation UpdateIssue($id: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $id, input: $input) { success issue { id } }
          }
        GRAPHQL
        mutation_id!(payload, "issue")
      end

      def link_pr(external_id:, pr_url:, pr_title:)
        payload = execute(<<~GRAPHQL, { input: { issueId: external_id, url: pr_url, title: pr_title } }).fetch("attachmentCreate")
          mutation LinkPullRequest($input: AttachmentCreateInput!) {
            attachmentCreate(input: $input) { success attachment { id } }
          }
        GRAPHQL
        mutation_id!(payload, "attachment")
      end

      # @spec UNIFIED-WORK-ITEMS-002
      def validate_connection!
        execute("query ValidateLinearConnection { viewer { id } }").fetch("viewer").fetch("id")
        true
      end

      private

      def issue_data(node)
        IssueData.new(external_id: node.fetch("id"), title: node.fetch("title"),
          body: node["description"], status: node.dig("state", "name"), url: node["url"],
          labels: Array(node.dig("labels", "nodes")).map { |label| label.fetch("name") },
          assignee: node["assignee"],
          metadata: { "identifier" => node["identifier"], "raw_payload" => node })
      end

      def mutation_id!(payload, field)
        raise ResponseError, "Linear #{field} mutation did not succeed" unless payload.fetch("success")

        payload.fetch(field).fetch("id")
      end

      def execute(query, variables = {})
        api_key = credential&.api_secret
        raise AuthenticationError, "Active Linear credential is required" unless credential&.active? && credential.service_key == "linear" && api_key.present?

        response = connection.post do |request|
          request.headers["Authorization"] = api_key
          request.headers["Content-Type"] = "application/json"
          request.body = JSON.generate(query:, variables:)
        end
        raise RateLimitedError.new(retry_after: response.headers["retry-after"].to_i) if response.status == 429
        raise AuthenticationError, "Linear rejected the credential" if [ 401, 403 ].include?(response.status)
        raise ResponseError, "Linear returned HTTP #{response.status}" unless response.success?

        payload = JSON.parse(response.body.to_s)
        errors = Array(payload["errors"])
        if errors.any?
          code = errors.first.dig("extensions", "code")
          raise AuthenticationError, "Linear rejected the credential" if code.to_s.match?(/AUTH|FORBIDDEN/i)
          raise RateLimitedError.new(retry_after: response.headers["retry-after"].to_i) if code == "RATELIMITED"

          raise ResponseError, "Linear GraphQL error: #{errors.first.fetch('message', 'unknown error')}"
        end

        payload["data"] || raise(ResponseError, "Linear response did not contain data")
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => error
        raise ResponseError, "Linear request failed: #{error.message}"
      rescue JSON::ParserError
        raise ResponseError, "Linear returned invalid JSON"
      end

      def connection
        @connection ||= Faraday.new(url: ENDPOINT) do |faraday|
          faraday.options.open_timeout = 5
          faraday.options.timeout = 20
        end
      end
    end
  end
end
