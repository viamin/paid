# frozen_string_literal: true

require "aws-sdk-s3"
module Screenshots
  # Uploads screenshot PNG files (and trace-derived artifacts like `.gif` and
  # `.webm`) to S3-compatible object storage and returns presigned object URLs
  # for inline viewing in PR comments and demo content.
  #
  # Files are organized by: screenshots/{org}/{repo}/pr-{number}/{commit_sha}/{route_name}.{ext}
  #
  # S3 client construction, bucket/region/credential resolution, and the generic
  # upload / signed-URL / delete operations are delegated to the shared
  # {ArtifactStorage} module so every durable artifact type reuses one storage
  # abstraction. This class keeps the screenshot-specific key layout and the
  # before/after listing logic.
  #
  # @example Upload a screenshot
  #   storage = Screenshots::Storage.new
  #   url = storage.upload(
  #     file_path: "/tmp/screenshots/dashboard.png",
  #     org: "acme",
  #     repo: "web",
  #     pr_number: 42,
  #     commit_sha: "abc1234",
  #     route_name: "dashboard"
  #   )
  #
  # @example Upload a trace-derived animated GIF
  #   storage.upload_artifact(
  #     file_path: "/tmp/demo.gif",
  #     org: "acme",
  #     repo: "web",
  #     pr_number: 42,
  #     commit_sha: "abc1234",
  #     route_name: "dashboard"
  #   )
  # @spec ARTIFACT-STORAGE-003
  class Storage
    class StorageError < StandardError; end

    # Storage/client configuration is delegated to {ArtifactStorage}. These
    # constants are aliased so historical references
    # (`Screenshots::Storage::MAX_URL_TTL`, etc.) keep resolving.
    DEFAULT_BUCKET = ArtifactStorage::DEFAULT_BUCKET
    DEFAULT_REGION = ArtifactStorage::DEFAULT_REGION
    # AWS SigV4 presigned S3 URLs cannot exceed one week.
    MAX_URL_TTL = ArtifactStorage::MAX_URL_TTL
    DEFAULT_URL_TTL = ArtifactStorage::DEFAULT_URL_TTL

    DEFAULT_RETENTION_DAYS = 30
    PNG_CONTENT_TYPE = "image/png"
    GIF_CONTENT_TYPE = "image/gif"
    WEBM_CONTENT_TYPE = "video/webm"
    SUPPORTED_ARTIFACT_EXTENSIONS = %w[.png .gif .webm].freeze
    ARTIFACT_CONTENT_TYPES = {
      ".png" => PNG_CONTENT_TYPE,
      ".gif" => GIF_CONTENT_TYPE,
      ".webm" => WEBM_CONTENT_TYPE
    }.freeze

    # The S3 key namespace every artifact key builder below writes under.
    # The durable output manifest's trusted lane
    # (`ExecutionRunners::ExecutionOutputManifest`) only honors persisted
    # locator keys under this prefix for the run's own project, so a key
    # planted under another tenant's namespace can never be re-signed into a
    # working presigned URL.
    # @spec CONTAINER-RUNTIME-018
    # @return [String]
    def self.namespace_prefix(org:, repo:)
      "screenshots/#{org}/#{repo}/"
    end

    def initialize(bucket: nil, region: nil, url_ttl: nil)
      @artifact_storage = ArtifactStorage.new(bucket: bucket, region: region, url_ttl: url_ttl)
    end

    # The shared artifact storage backend that owns S3 client construction.
    attr_reader :artifact_storage

    # The S3 bucket screenshots and traces share. Exposed so sibling services
    # (e.g. {Previews::TraceViewer}) can address the same bucket.
    def bucket
      @artifact_storage.bucket
    end

    # The AWS region for the configured bucket.
    def region
      @artifact_storage.region
    end

    # Underlying S3 client, delegated to {ArtifactStorage}. Exposed so sibling
    # services that operate on the shared bucket (trace existence checks, trace
    # uploads) can reuse it instead of constructing a second, potentially
    # divergent client.
    def s3_client
      @artifact_storage.client
    end

    # Uploads a PNG screenshot to S3 and returns a presigned URL.
    #
    # @param file_path [String] Path to the local PNG file
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    # @param commit_sha [String] Commit SHA
    # @param route_name [String] Route slug for the screenshot
    # @return [String] Presigned GET URL for the uploaded file
    def upload(file_path:, org:, repo:, pr_number:, commit_sha:, route_name:)
      upload_artifact(
        file_path: file_path,
        org: org,
        repo: repo,
        pr_number: pr_number,
        commit_sha: commit_sha,
        route_name: route_name,
        extension: ".png"
      )
    end

    # Uploads a trace-derived artifact (`.png`, `.gif`, or `.webm`) to S3 and
    # returns a presigned URL. The artifact's content type is inferred from its
    # extension.
    #
    # @param file_path [String] Path to the local artifact file
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    # @param commit_sha [String] Commit SHA
    # @param route_name [String] Route slug for the artifact (used as the
    #   filename stem; the extension is taken from `extension` when provided)
    # @param extension [String] File extension including leading dot; defaults
    #   to the extension of `file_path`. Use this when the local file has a
    #   different extension than what should be stored in S3.
    # @return [String] Presigned GET URL for the uploaded file
    def upload_artifact(file_path:, org:, repo:, pr_number:, commit_sha:, route_name:, extension: nil)
      resolved_extension = extension || File.extname(file_path).downcase
      content_type = ARTIFACT_CONTENT_TYPES[resolved_extension]
      raise StorageError, "unsupported artifact extension #{resolved_extension.inspect}" if content_type.nil?

      key = artifact_key(org:, repo:, pr_number:, commit_sha:, route_name:, extension: resolved_extension)

      put_object(file_path:, key:, content_type:)
      signed_url(key)
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 upload failed: #{e.message}"
    end

    # Uploads an in-memory document (the page load ledger) under a caller-built
    # key. Unlike the artifact uploads above, the body is generated rather than
    # read from a captured file.
    # @spec PAGE-LOAD-EXPORT-001
    def upload_document(key:, body:, content_type: "application/json")
      s3_client.put_object(bucket: bucket, key: key, body: body, content_type: content_type)
      key
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 document upload failed: #{e.message}"
    end

    def upload_trace(file_path:, org:, repo:, pr_number:, commit_sha:)
      key = trace_object_key(org:, repo:, pr_number:, commit_sha:)
      put_object(file_path:, key:, content_type: "application/zip")
      signed_url(key)
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 trace upload failed: #{e.message}"
    end

    def upload_video(file_path:, org:, repo:, pr_number:, commit_sha:)
      key = video_object_key(org:, repo:, pr_number:, commit_sha:)
      put_object(file_path:, key:, content_type: "video/webm")
      signed_url(key)
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 video upload failed: #{e.message}"
    end

    # Generates a signed URL for an existing S3 object.
    #
    # @param key [String] S3 object key
    # @return [String] Presigned GET URL
    def signed_url(key)
      @artifact_storage.signed_url(key)
    end

    # Returns signed URLs for the most recent previous commit's screenshots,
    # excluding the current commit. Used for before/after comparison in PR comments.
    #
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    # @param exclude_sha [String] Current commit SHA to exclude
    # @return [Hash<String, String>] Mapping of route_name to signed URL
    def previous_screenshots(org:, repo:, pr_number:, exclude_sha:)
      prefix = "screenshots/#{org}/#{repo}/pr-#{pr_number}/"
      commits = Hash.new { |h, k| h[k] = [] }

      s3_client.list_objects_v2(bucket: bucket, prefix: prefix).each_page do |page|
        page.contents.each do |obj|
          next unless obj.key.end_with?(".png")

          parts = obj.key.delete_prefix(prefix).split("/", 2)
          next unless parts.size == 2

          sha = parts[0]
          next if sha == exclude_sha

          commits[sha] << obj
        end
      end

      return {} if commits.empty?

      latest_sha = commits.max_by { |_, objects| objects.map(&:last_modified).max }.first
      commits[latest_sha].each_with_object({}) do |obj, result|
        next unless obj.key.end_with?(".png")

        route_name = File.basename(obj.key, ".png")
        result[route_name] = signed_url(obj.key)
      end
    rescue Aws::S3::Errors::ServiceError
      {}
    end

    # Returns signed URLs for the most recent previous commit's trace-derived
    # artifacts (PNG, GIF, WebM), grouped by route_name. Each route may have
    # multiple formats available (e.g., `:png` and `:gif`). Used to upgrade
    # PR comments with animated GIFs alongside or instead of static PNGs.
    #
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    # @param exclude_sha [String] Current commit SHA to exclude
    # @param extensions [Array<String>] File extensions to include; defaults
    #   to all supported artifact formats (`.png`, `.gif`, `.webm`)
    # @return [Hash<String, Hash<Symbol, String>>] Mapping of route_name to a
    #   hash of format symbol (`:png`, `:gif`, `:webm`) to signed URL
    def previous_artifacts(org:, repo:, pr_number:, exclude_sha:, extensions: SUPPORTED_ARTIFACT_EXTENSIONS)
      prefix = "screenshots/#{org}/#{repo}/pr-#{pr_number}/"
      allowed_extensions = Array(extensions).map(&:downcase)
      commits = Hash.new { |h, k| h[k] = [] }

      s3_client.list_objects_v2(bucket: bucket, prefix: prefix).each_page do |page|
        page.contents.each do |obj|
          parts = obj.key.delete_prefix(prefix).split("/", 2)
          next unless parts.size == 2

          sha = parts[0]
          next if sha == exclude_sha

          commits[sha] << obj
        end
      end

      return {} if commits.empty?

      latest_sha = commits.max_by { |_, objects| objects.map(&:last_modified).max }.first
      grouped = Hash.new { |h, k| h[k] = {} }

      commits[latest_sha].each do |obj|
        ext = File.extname(obj.key).downcase
        next unless allowed_extensions.include?(ext)

        route_name = File.basename(obj.key, ext)
        format = ext.delete_prefix(".").to_sym
        grouped[route_name][format] = signed_url(obj.key)
      end

      grouped
    rescue Aws::S3::Errors::ServiceError
      {}
    end

    # Deletes all screenshots for a given PR.
    #
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    def delete_pr_screenshots(org:, repo:, pr_number:)
      prefix = "screenshots/#{org}/#{repo}/pr-#{pr_number}/"
      @artifact_storage.delete_prefix(prefix)
    end

    # Deletes screenshots older than the retention period.
    #
    # @param retention_days [Integer] Number of days to retain screenshots
    # @return [Integer] Number of objects deleted
    def cleanup_old_screenshots(retention_days: DEFAULT_RETENTION_DAYS)
      cutoff = retention_days.days.ago
      deleted_count = 0

      s3_client.list_objects_v2(bucket: bucket, prefix: "screenshots/").each_page do |page|
        old_objects = page.contents.select { |obj| obj.last_modified < cutoff }
        next if old_objects.empty?

        s3_client.delete_objects(
          bucket: bucket,
          delete: { objects: old_objects.map { |obj| { key: obj.key } } }
        )
        deleted_count += old_objects.size
      end

      deleted_count
    end

    # Returns whether storage is properly configured.
    #
    # @return [Boolean]
    def self.configured?
      ArtifactStorage.configured?
    end

    def configured?
      @artifact_storage.configured?
    end

    # Builds the S3 object key for a screenshot.
    #
    # @return [String]
    def object_key(org:, repo:, pr_number:, commit_sha:, route_name:)
      "#{namespace_prefix(org:, repo:)}pr-#{pr_number}/#{commit_sha}/#{route_name}.png"
    end

    # Builds the S3 object key for a trace-derived artifact (PNG/GIF/WebM).
    #
    # @param extension [String] File extension including leading dot
    # @return [String]
    def artifact_key(org:, repo:, pr_number:, commit_sha:, route_name:, extension:)
      "#{namespace_prefix(org:, repo:)}pr-#{pr_number}/#{commit_sha}/#{route_name}#{extension}"
    end

    def trace_object_key(org:, repo:, pr_number:, commit_sha:)
      "#{namespace_prefix(org:, repo:)}pr-#{pr_number}/#{commit_sha}/trace.zip"
    end

    def video_object_key(org:, repo:, pr_number:, commit_sha:)
      "#{namespace_prefix(org:, repo:)}pr-#{pr_number}/#{commit_sha}/capture.webm"
    end

    private

    def namespace_prefix(org:, repo:)
      self.class.namespace_prefix(org:, repo:)
    end

    def put_object(file_path:, key:, content_type:)
      File.open(file_path, "rb") do |file|
        s3_client.put_object(
          bucket: bucket,
          key: key,
          body: file,
          content_type: content_type
        )
      end
    end
  end
end
