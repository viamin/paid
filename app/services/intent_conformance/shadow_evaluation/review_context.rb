# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Read-only context from exact repository revisions, never from corpus answer
    # hints. This resolves the same baseline for the human and automated reviewer.
    # @spec INTENT-CONFORMANCE-ROLLOUT-013
    class ReviewContext
      MAX_DOCUMENTS = 6
      MAX_DOCUMENT_LENGTH = 20_000

      def self.call(...) = new(...).call

      def initialize(corpus_case:, comparison:, client:, default_paths: [])
        @item = corpus_case
        @comparison = comparison.to_h.deep_symbolize_keys
        @client = client
        @default_paths = default_paths
      end

      def call
        { summary: summary, documents: documents, file_count: files.size }
      end

      private

      attr_reader :item, :comparison, :client, :default_paths

      def repository = item.fetch("repository")
      def files = Array(comparison[:files])

      def head_commit_title
        entry = Array(comparison[:commits]).reverse.find { |commit| commit[:sha] == item["head_sha"] }
        (entry&.dig(:commit, :message) || entry&.dig(:message)).to_s.lines.first.to_s.strip.truncate(240)
      end

      def pull_request
        return @pull_request if defined?(@pull_request)

        number = head_commit_title[/\(#(\d+)\)\z/, 1]
        @pull_request = number && client.pull_request(repository, number.to_i)&.to_h&.deep_symbolize_keys
        return @pull_request if @pull_request && matching_pull_request?(@pull_request)

        @pull_request = nil
      rescue GithubClient::Error
        @pull_request = nil
      end

      def matching_pull_request?(pr)
        pr[:merge_commit_sha] == item["head_sha"] ||
          (pr.dig(:base, :sha) == item["base_sha"] && pr.dig(:head, :sha) == item["head_sha"])
      end

      def summary
        if (pr = pull_request)
          number = head_commit_title[/\(#(\d+)\)\z/, 1]
          { title: pr[:title].to_s.truncate(240), body: pr[:body].to_s.truncate(3_000),
            source: "Pull request ##{number}", url: "https://github.com/#{repository}/pull/#{number}" }
        else
          { title: head_commit_title.presence || "Code changes in #{repository}", body: nil,
            source: "Git commit", url: "https://github.com/#{repository}/commit/#{item.fetch('head_sha')}" }
        end
      end

      def documents
        declared = Array(item["design_document_paths"]).presence || default_paths.presence
        paths = declared || recovered_paths
        found = paths.uniq.first(MAX_DOCUMENTS).filter_map { |path| read_document(path, declared ? "declared" : "recovered") }
        return found if found.any? || declared

        [ read_document("docs/high-level-design.md", "overview") ].compact
      end

      def recovered_paths
        changed = files.filter_map { |file| file[:filename] if file[:filename].to_s.start_with?("docs/intent/", "docs/rdrs/") }
        referenced = pull_request&.fetch(:body, nil).to_s.scan(%r{\bdocs/(?:[a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+\.md\b})
        changed + referenced
      end

      def read_document(path, source)
        return unless path.is_a?(String) && path.end_with?(".md") && valid_path?(path)
        return unless item["approved_design_revision"].to_s.match?(Evidence::SHA)

        content = client.file_content(repository, path:, ref: item.fetch("approved_design_revision"))
        return if content.blank?

        escaped = path.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
        { path:, content: content.truncate(MAX_DOCUMENT_LENGTH), source:,
          url: "https://github.com/#{repository}/blob/#{item.fetch('approved_design_revision')}/#{escaped}" }
      rescue GithubClient::NotFoundError
        nil
      end

      def valid_path?(path)
        path.split("/", -1).all? { |part| part.present? && part != "." && part != ".." && part.match?(Evidence::PATH_SEGMENT) }
      end
    end
  end
end
