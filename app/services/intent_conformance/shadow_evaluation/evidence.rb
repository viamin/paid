# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Validates one pinned repository artifact immediately before navigating
    # there or returning an escaped-text preview through the authorized evidence
    # endpoint. All reads stay pinned to the case's recorded revisions.
    # @spec INTENT-CONFORMANCE-ROLLOUT-010
    class Evidence
      Result = Data.define(:available, :url, :error, :files, :context) do
        def initialize(available:, url: nil, error: nil, files: [], context: {})
          super
        end

        def available? = available
      end

      MAX_FILES = 30
      MAX_PATCH_BYTES = 200_000

      SHA = /\A[0-9a-f]{40}\z/i
      PATH_SEGMENT = /\A[a-zA-Z0-9._-]+\z/
      CHANGED_MANIFEST_ERROR = "corpus manifest changed since the evaluation was created — start a new evaluation"

      def self.call(...) = new(...).call

      def initialize(evaluation:, case_id:, kind:, path: nil, client: nil)
        @evaluation = evaluation
        @case_id = case_id
        @kind = kind
        @path = path
        @client = client
      end

      def call
        # A changed corpus is a new evidence generation: never read or validate
        # a manifest that was edited after the evaluation was created, even
        # when a retained case id makes the replacement look familiar.
        return unavailable(CHANGED_MANIFEST_ERROR) unless evaluation.corpus.matches_recorded_digest?
        return unavailable("case is not part of the frozen corpus") unless corpus_case
        return unavailable("case repository is outside this project") unless repository == project.full_name
        return unavailable("case repository identity is invalid") unless valid_repository?
        return unavailable("repository access is not configured") unless client

        %w[diff inline_diff review_context].include?(kind) ? diff : design_document
      rescue GithubClient::Error,
        IntentConformance::ShadowEvaluationCorpus::MissingManifest,
        Errno::ENOENT,
        Psych::Exception
        unavailable("pinned evidence is unavailable")
      end

      private

      attr_reader :evaluation, :case_id, :kind, :path

      def corpus_case
        @corpus_case ||= evaluation.corpus.find_case(case_id)
      end

      def project = evaluation.project

      def client = @client ||= project.client

      def repository = corpus_case.fetch("repository", "")

      def diff
        return unavailable("pinned diff has an invalid revision") unless valid_sha?(base_sha) && valid_sha?(head_sha)

        comparison = client.compare(repository, base_sha, head_sha)
        files = kind == "diff" ? [] : preview_files(comparison)
        context = kind == "review_context" ? ReviewContext.call(corpus_case:, comparison:, client:,
          default_paths: evaluation.corpus.design_document_paths) : {}
        Result.new(available: true, url: diff_url, files:, context:)
      end

      def preview_files(comparison)
        remaining = MAX_PATCH_BYTES
        Array(comparison[:files]).first(MAX_FILES).map do |file|
          values = file.to_h.symbolize_keys
          fields = values.slice(:filename, :status, :additions, :deletions)
          patch = values[:patch] if values[:patch].is_a?(String)
          preview = patch&.byteslice(0, remaining)&.scrub("")
          remaining -= preview.to_s.bytesize
          fields.merge(patch: preview, truncated: patch.to_s.bytesize > preview.to_s.bytesize)
        end
      end

      def design_document
        return unavailable("approved design artifact is not declared for this case") unless declared_document?
        return unavailable("approved design artifact path is invalid") unless valid_path?(path)
        return unavailable("approved design revision is invalid") unless valid_sha?(revision)
        return unavailable("approved design artifact is unavailable") if client.file_content(repository, path:, ref: revision).blank?

        available(document_url)
      end

      def base_sha = corpus_case.fetch("base_sha", "")
      def head_sha = corpus_case.fetch("head_sha", "")
      def revision = corpus_case.fetch("approved_design_revision", "")

      def declared_document?
        Array(corpus_case["design_document_paths"]).include?(path)
      end

      def valid_sha?(value) = value.is_a?(String) && value.match?(SHA)

      def valid_repository?
        repository.split("/", -1).length == 2 && valid_segments?(repository)
      end

      def valid_path?(value)
        value.is_a?(String) && value.present? && valid_segments?(value)
      end

      def valid_segments?(value)
        value.split("/", -1).all? { |segment| segment.present? && segment != "." && segment != ".." && segment.match?(PATH_SEGMENT) }
      end

      def diff_url = "https://github.com/#{repository}/compare/#{base_sha}...#{head_sha}"

      def document_url
        escaped_path = path.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
        "https://github.com/#{repository}/blob/#{revision}/#{escaped_path}"
      end

      def available(url) = Result.new(available: true, url:, error: nil)
      def unavailable(error) = Result.new(available: false, url: nil, error:)
    end
  end
end
