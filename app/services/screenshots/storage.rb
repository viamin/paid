# frozen_string_literal: true

require "aws-sdk-s3"
module Screenshots
  # Uploads screenshot PNG files (and trace-derived artifacts like `.gif` and
  # `.webm`) to S3-compatible object storage and returns presigned object URLs
  # for inline viewing in PR comments and demo content.
  #
  # Files are organized by: screenshots/{org}/{repo}/pr-{number}/{commit_sha}/{route_name}.{ext}
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
  class Storage
    class StorageError < StandardError; end

    DEFAULT_BUCKET = "paid-screenshots"
    DEFAULT_REGION = "us-east-1"
    DEFAULT_RETENTION_DAYS = 30
    # AWS SigV4 presigned S3 URLs cannot exceed one week.
    MAX_URL_TTL = Aws::S3::Presigner::ONE_WEEK
    DEFAULT_URL_TTL = MAX_URL_TTL
    PNG_CONTENT_TYPE = "image/png"
    GIF_CONTENT_TYPE = "image/gif"
    WEBM_CONTENT_TYPE = "video/webm"
    SUPPORTED_ARTIFACT_EXTENSIONS = %w[.png .gif .webm].freeze
    ARTIFACT_CONTENT_TYPES = {
      ".png" => PNG_CONTENT_TYPE,
      ".gif" => GIF_CONTENT_TYPE,
      ".webm" => WEBM_CONTENT_TYPE
    }.freeze

    def initialize(bucket: nil, region: nil, url_ttl: nil)
      @bucket = bucket || configured_bucket
      @region = region || configured_region
      @url_ttl = url_ttl
    end

    # The S3 bucket screenshots and traces share. Exposed so sibling services
    # (e.g. {Previews::TraceViewer}) can address the same bucket.
    attr_reader :bucket

    # The AWS region for the configured bucket.
    attr_reader :region

    # Underlying S3 client. Exposed so sibling services that operate on the
    # shared bucket (trace existence checks, trace uploads) can reuse it
    # instead of constructing a second, potentially divergent client.
    def s3_client
      @s3_client ||= Aws::S3::Client.new(client_options)
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

      File.open(file_path, "rb") do |file|
        s3_client.put_object(
          bucket: @bucket,
          key: key,
          body: file,
          content_type: content_type
        )
      end
      signed_url(key)
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 upload failed: #{e.message}"
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
      presigner.presigned_url(
        :get_object,
        bucket: @bucket,
        key: key,
        expires_in: url_ttl.to_i
      )
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

      s3_client.list_objects_v2(bucket: @bucket, prefix: prefix).each_page do |page|
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

      s3_client.list_objects_v2(bucket: @bucket, prefix: prefix).each_page do |page|
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
      delete_by_prefix(prefix)
    end

    # Deletes screenshots older than the retention period.
    #
    # @param retention_days [Integer] Number of days to retain screenshots
    # @return [Integer] Number of objects deleted
    def cleanup_old_screenshots(retention_days: DEFAULT_RETENTION_DAYS)
      cutoff = retention_days.days.ago
      deleted_count = 0

      s3_client.list_objects_v2(bucket: @bucket, prefix: "screenshots/").each_page do |page|
        old_objects = page.contents.select { |obj| obj.last_modified < cutoff }
        next if old_objects.empty?

        s3_client.delete_objects(
          bucket: @bucket,
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
      configured_access_key_id.present? && configured_secret_access_key.present?
    end

    def configured?
      access_key_id.present? && secret_access_key.present?
    end

    # Builds the S3 object key for a screenshot.
    #
    # @return [String]
    def object_key(org:, repo:, pr_number:, commit_sha:, route_name:)
      "screenshots/#{org}/#{repo}/pr-#{pr_number}/#{commit_sha}/#{route_name}.png"
    end

    # Builds the S3 object key for a trace-derived artifact (PNG/GIF/WebM).
    #
    # @param extension [String] File extension including leading dot
    # @return [String]
    def artifact_key(org:, repo:, pr_number:, commit_sha:, route_name:, extension:)
      "screenshots/#{org}/#{repo}/pr-#{pr_number}/#{commit_sha}/#{route_name}#{extension}"
    end

    def trace_object_key(org:, repo:, pr_number:, commit_sha:)
      "screenshots/#{org}/#{repo}/pr-#{pr_number}/#{commit_sha}/trace.zip"
    end

    def video_object_key(org:, repo:, pr_number:, commit_sha:)
      "screenshots/#{org}/#{repo}/pr-#{pr_number}/#{commit_sha}/capture.webm"
    end

    private

    def put_object(file_path:, key:, content_type:)
      File.open(file_path, "rb") do |file|
        s3_client.put_object(
          bucket: @bucket,
          key: key,
          body: file,
          content_type: content_type
        )
      end
    end

    def delete_by_prefix(prefix)
      s3_client.list_objects_v2(bucket: @bucket, prefix: prefix).each_page do |page|
        next if page.contents.empty?

        s3_client.delete_objects(
          bucket: @bucket,
          delete: { objects: page.contents.map { |obj| { key: obj.key } } }
        )
      end
    end

    def presigner
      @presigner ||= Aws::S3::Presigner.new(client: s3_client)
    end

    def url_ttl
      @url_ttl ||= configured_url_ttl
    end

    def client_options
      opts = { region: @region }
      opts[:access_key_id] = access_key_id if access_key_id.present?
      opts[:secret_access_key] = secret_access_key if secret_access_key.present?
      opts[:endpoint] = endpoint if endpoint.present?
      opts[:force_path_style] = true if endpoint.present?
      opts
    end

    def configured_bucket
      ENV.fetch("SCREENSHOTS_S3_BUCKET", credentials_dig(:bucket) || DEFAULT_BUCKET)
    end

    def configured_region
      ENV.fetch("SCREENSHOTS_S3_REGION", credentials_dig(:region) || DEFAULT_REGION)
    end

    def configured_url_ttl
      value = ENV["SCREENSHOTS_S3_URL_TTL"] || credentials_dig(:url_ttl)
      return DEFAULT_URL_TTL if value.blank?

      ttl = Integer(value)
      raise ArgumentError, "SCREENSHOTS_S3_URL_TTL must be positive" unless ttl.positive?
      raise ArgumentError, "SCREENSHOTS_S3_URL_TTL cannot exceed #{MAX_URL_TTL} seconds for S3 presigned URLs" if ttl > MAX_URL_TTL

      ttl
    end

    def access_key_id
      self.class.send(:configured_access_key_id)
    end

    def secret_access_key
      self.class.send(:configured_secret_access_key)
    end

    def endpoint
      self.class.send(:configured_endpoint)
    end

    def credentials_dig(key)
      Rails.application.credentials.dig(:screenshots, :s3, key)
    end

    class << self
      private

      def configured_access_key_id
        ENV["SCREENSHOTS_S3_ACCESS_KEY_ID"] || credentials_dig(:access_key_id)
      end

      def configured_secret_access_key
        ENV["SCREENSHOTS_S3_SECRET_ACCESS_KEY"] || credentials_dig(:secret_access_key)
      end

      def configured_endpoint
        ENV["SCREENSHOTS_S3_ENDPOINT"] || credentials_dig(:endpoint)
      end

      def credentials_dig(key)
        Rails.application.credentials.dig(:screenshots, :s3, key)
      end
    end
  end
end
