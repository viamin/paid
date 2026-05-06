# frozen_string_literal: true

require "aws-sdk-s3"

module Screenshots
  # Uploads screenshot PNG files to S3-compatible object storage and generates
  # signed URLs for inline viewing in PR comments.
  #
  # Files are organized by: screenshots/{org}/{repo}/pr-{number}/{commit_sha}/{route_name}.png
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
  class Storage
    class StorageError < StandardError; end

    DEFAULT_BUCKET = "paid-screenshots"
    DEFAULT_REGION = "us-east-1"
    DEFAULT_URL_TTL = 7.days
    DEFAULT_RETENTION_DAYS = 30

    def initialize(bucket: nil, region: nil, url_ttl: nil)
      @bucket = bucket || configured_bucket
      @region = region || configured_region
      @url_ttl = url_ttl || DEFAULT_URL_TTL
    end

    # Uploads a PNG file to S3 and returns a signed URL.
    #
    # @param file_path [String] Path to the local PNG file
    # @param org [String] GitHub org/owner
    # @param repo [String] Repository name
    # @param pr_number [Integer] Pull request number
    # @param commit_sha [String] Commit SHA
    # @param route_name [String] Route slug for the screenshot
    # @return [String] Signed URL for the uploaded file
    def upload(file_path:, org:, repo:, pr_number:, commit_sha:, route_name:)
      key = object_key(org:, repo:, pr_number:, commit_sha:, route_name:)

      File.open(file_path, "rb") do |file|
        s3_client.put_object(
          bucket: @bucket,
          key: key,
          body: file,
          content_type: "image/png"
        )
      end

      signed_url(key)
    rescue Aws::S3::Errors::ServiceError => e
      raise StorageError, "S3 upload failed: #{e.message}"
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
        expires_in: @url_ttl.to_i
      )
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
      new.configured?
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

    private

    def delete_by_prefix(prefix)
      s3_client.list_objects_v2(bucket: @bucket, prefix: prefix).each_page do |page|
        next if page.contents.empty?

        s3_client.delete_objects(
          bucket: @bucket,
          delete: { objects: page.contents.map { |obj| { key: obj.key } } }
        )
      end
    end

    def s3_client
      @s3_client ||= Aws::S3::Client.new(client_options)
    end

    def presigner
      @presigner ||= Aws::S3::Presigner.new(client: s3_client)
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

    def access_key_id
      ENV["SCREENSHOTS_S3_ACCESS_KEY_ID"] || credentials_dig(:access_key_id)
    end

    def secret_access_key
      ENV["SCREENSHOTS_S3_SECRET_ACCESS_KEY"] || credentials_dig(:secret_access_key)
    end

    def endpoint
      ENV["SCREENSHOTS_S3_ENDPOINT"] || credentials_dig(:endpoint)
    end

    def credentials_dig(key)
      Rails.application.credentials.dig(:screenshots, :s3, key)
    end
  end
end
