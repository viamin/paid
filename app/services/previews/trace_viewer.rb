# frozen_string_literal: true

require "aws-sdk-s3"

module Previews
  # Serves the Playwright Trace Viewer from S3 and builds embeddable URLs so a
  # trace (`.zip`) recorded during an agent run can be scrubbed through inside
  # the Paid UI via an iframe.
  # @spec LIVE-PREVIEW-006
  #
  # The Playwright Trace Viewer is a static web application. When it is hosted
  # (e.g. uploaded to S3 under {#viewer_object_key}) it loads a trace from a URL
  # via a `trace` query parameter. This service:
  #
  # * uploads the trace viewer static bundle to S3 (once),
  # * resolves a stored trace `.zip` for a given PR/commit to a presigned URL,
  # * builds the embeddable viewer URL (viewer index + `?trace=<signed url>`),
  # * reports whether a trace is available so the UI can degrade gracefully.
  #
  # The trace viewer reads bucket/region/credentials from the same
  # configuration as the screenshot pipeline (the shared {ArtifactStorage}
  # module); {Screenshots::Storage} only contributes the trace object-key
  # contract.
  #
  # @example Build an embeddable URL for a stored trace
  #   viewer = Previews::TraceViewer.new
  #   viewer.embed_url(org: "acme", repo: "web", pr_number: 42, commit_sha: "abc1234")
  #   # => "https://bucket.s3.../trace-viewer/index.html?trace=https%3A%2F%2F...trace.zip%3F..."
  class TraceViewer
    class TraceViewerError < StandardError; end

    DEFAULT_VIEWER_PREFIX = "trace-viewer"
    DEFAULT_VIEWER_INDEX = "index.html"
    DEFAULT_TRACE_FILENAME = "trace.zip"
    TRACE_QUERY_PARAM = "trace"

    # @param storage [Screenshots::Storage] Storage backend that owns the trace
    #   object-key contract. Defaults to a new {Screenshots::Storage}.
    # @param artifact_storage [ArtifactStorage, nil] Object storage backend used
    #   for every S3 access (presigned URLs, `head_object`, `put_object`).
    #   Defaults to the backend composed by `storage` so injected bucket/region
    #   overrides stay aligned between writes and reads.
    # @param viewer_prefix [String] S3 key prefix where the trace viewer static
    #   bundle is served from.
    def initialize(storage: Screenshots::Storage.new, artifact_storage: nil, viewer_prefix: DEFAULT_VIEWER_PREFIX)
      @storage = storage
      @artifact_storage = artifact_storage || storage.artifact_storage
      @viewer_prefix = viewer_prefix.to_s
    end

    # Whether object storage is configured enough to serve traces.
    #
    # @return [Boolean]
    def configured?
      @artifact_storage.configured?
    end

    # Builds the S3 object key for a trace `.zip`.
    #
    # @return [String]
    def trace_object_key(org:, repo:, pr_number:, commit_sha:)
      @storage.trace_object_key(org:, repo:, pr_number:, commit_sha:)
    end

    # Returns a presigned GET URL for a stored trace `.zip`.
    #
    # @return [String]
    def trace_url(org:, repo:, pr_number:, commit_sha:)
      @artifact_storage.signed_url(trace_object_key(org:, repo:, pr_number:, commit_sha:))
    end

    # Whether a trace `.zip` exists for the given PR/commit.
    #
    # Returns false (rather than raising) on storage errors or missing
    # configuration so callers can degrade gracefully.
    #
    # @return [Boolean]
    def trace_available?(org:, repo:, pr_number:, commit_sha:)
      return false unless configured?

      key = trace_object_key(org:, repo:, pr_number:, commit_sha:)
      @artifact_storage.client.head_object(bucket: @artifact_storage.bucket, key: key)
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::Forbidden, Aws::S3::Errors::ServiceError
      false
    end

    # Builds the embeddable trace viewer URL that loads a stored trace.
    #
    # @return [String] Viewer index URL with a `trace=<signed url>` query param.
    def embed_url(org:, repo:, pr_number:, commit_sha:)
      viewer_url(trace_url: trace_url(org:, repo:, pr_number:, commit_sha:))
    end

    # Builds an embeddable viewer URL for an explicit trace URL (e.g. a trace
    # already uploaded by the recording pipeline).
    #
    # The trace URL is appended as a `trace` query parameter. Presigned S3 viewer
    # URLs already carry a query string, so `&` is used when one is present.
    #
    # @param trace_url [String] Presigned URL of the trace `.zip`.
    # @return [String]
    def viewer_url(trace_url:)
      index = viewer_index_url
      separator = index.include?("?") ? "&" : "?"
      "#{index}#{separator}#{TRACE_QUERY_PARAM}=#{url_escape(trace_url)}"
    end

    # Presigned URL of the hosted trace viewer entry point.
    #
    # @return [String]
    def viewer_index_url
      @artifact_storage.signed_url(viewer_object_key)
    end

    # S3 object key for the trace viewer entry point.
    #
    # @return [String]
    def viewer_object_key
      "#{@viewer_prefix}/#{DEFAULT_VIEWER_INDEX}"
    end

    # Uploads the trace viewer static bundle (a directory of files produced by
    # `npx playwright build`) to S3 so it can be served via {viewer_index_url}.
    #
    # @param source_dir [String] Local directory containing the viewer bundle.
    # @return [Array<String>] The S3 object keys that were uploaded.
    def upload_viewer_assets!(source_dir)
      raise TraceViewerError, "viewer source dir not found: #{source_dir}" unless Dir.exist?(source_dir)

      uploaded = Dir.glob(File.join(source_dir, "**", "*")).sort.each_with_object([]) do |path, keys|
        next if File.directory?(path)

        relative = path.delete_prefix("#{source_dir.chomp(File::SEPARATOR)}/")
        key = "#{@viewer_prefix}/#{relative}"
        put_object(key: key, file_path: path, content_type: content_type_for(path))
        keys << key
      end

      raise TraceViewerError, "no viewer assets found in #{source_dir}" if uploaded.empty?

      uploaded
    end

    # Uploads a trace `.zip` to S3 and returns its presigned URL. Used by the
    # trace recording pipeline; exposed here for a single self-contained
    # interface over trace artifacts.
    #
    # @param file_path [String] Local path to the trace `.zip`.
    # @return [String] Presigned GET URL for the uploaded trace.
    def upload_trace(file_path:, org:, repo:, pr_number:, commit_sha:)
      @storage.upload_trace(file_path:, org:, repo:, pr_number:, commit_sha:)
    rescue Screenshots::Storage::StorageError => e
      raise TraceViewerError, "trace viewer upload failed: #{e.message}"
    end

    private

    def put_object(key:, file_path:, content_type:)
      File.open(file_path, "rb") do |file|
        @artifact_storage.client.put_object(
          bucket: @artifact_storage.bucket,
          key: key,
          body: file,
          content_type: content_type
        )
      end
    rescue Aws::S3::Errors::ServiceError => e
      raise TraceViewerError, "trace viewer upload failed: #{e.message}"
    end

    def content_type_for(path)
      Marcel::MimeType.for(Pathname.new(path)).presence || "application/octet-stream"
    end

    def url_escape(value)
      Addressable::URI.encode_component(value.to_s, Addressable::URI::CharacterClasses::UNRESERVED)
    end
  end
end
