# frozen_string_literal: true

require "aws-sdk-s3"

# Shared S3-compatible object storage for durable, user-visible artifacts.
#
# Paid's production invariant is that Rails and Temporal worker hosts are
# disposable: destroying or replacing a host must not destroy important state.
# Durable application state lives in PostgreSQL; durable *binary* artifacts
# (screenshots, Playwright traces, trace-viewer assets, and future artifact
# types such as generated reports or build outputs) live in object storage
# through this module. Nothing durable is written to the host filesystem.
# See `docs/ARTIFACT_STORAGE.md` for the complete artifact inventory.
#
# `ArtifactStorage` owns S3 client construction (region, credentials, endpoint,
# bucket, presigned-URL TTL) and the generic upload / signed-URL / delete
# operations that work for arbitrary key prefixes. Specialist services
# (`Screenshots::Storage`) delegate client construction here instead of building
# their own potentially divergent clients, while keeping their own key-layout
# and listing logic.
#
# Configuration is identical to the historical screenshot config and defaults to
# the `SCREENSHOTS_S3_*` environment variables / Rails credentials, so existing
# deployments need no changes. New artifact types can either reuse the same
# bucket (different key prefix) or a dedicated one via the `bucket:` override.
#
# @example Upload and later address a durable artifact
#   store = ArtifactStorage.new
#   url = store.upload(file_path: "/tmp/report.pdf", key: "reports/acme/pr-42/report.pdf")
#   store.signed_url("reports/acme/pr-42/report.pdf")
#   store.delete("reports/acme/pr-42/report.pdf")
#
# @spec ARTIFACT-STORAGE-001
# @spec ARTIFACT-STORAGE-002
# @spec ARTIFACT-STORAGE-004
class ArtifactStorage
  class StorageError < StandardError; end

  DEFAULT_BUCKET = "paid-screenshots"
  DEFAULT_REGION = "us-east-1"
  DEFAULT_CONTENT_TYPE = "application/octet-stream"
  # AWS SigV4 presigned S3 URLs cannot exceed one week.
  MAX_URL_TTL = Aws::S3::Presigner::ONE_WEEK
  DEFAULT_URL_TTL = MAX_URL_TTL

  # @param bucket [String, nil] override the configured bucket.
  # @param region [String, nil] override the configured region.
  # @param url_ttl [Integer, nil] presigned GET URL lifetime in seconds.
  def initialize(bucket: nil, region: nil, url_ttl: nil)
    @bucket = bucket || self.class.configured_bucket
    @region = region || self.class.configured_region
    @url_ttl = url_ttl
  end

  # @return [String] the configured bucket.
  attr_reader :bucket

  # @return [String] the configured AWS region.
  attr_reader :region

  # The underlying S3-compatible client. Reused by every operation in this
  # module and exposed so specialist services (e.g. `Screenshots::Storage`)
  # share a single client instead of constructing divergent ones.
  #
  # @return [Aws::S3::Client]
  def client
    @client ||= Aws::S3::Client.new(client_options)
  end

  # Backwards-compatible alias; `Screenshots::Storage` and `Previews::TraceViewer`
  # historically reached for `s3_client`. Implemented as a delegation (rather
  # than `alias`) so dependency-injected clients propagate through both names.
  #
  # @return [Aws::S3::Client]
  def s3_client
    client
  end

  # Whether object storage credentials are configured (env var or Rails
  # credential). Callers degrade gracefully when this is false.
  #
  # @return [Boolean]
  def configured?
    self.class.configured?
  end

  # Uploads a local file to object storage and returns a presigned GET URL.
  #
  # @param file_path [String] path to the local file to upload.
  # @param key [String] object key, including any prefix.
  # @param content_type [String, nil] MIME type; inferred from the file when
  #   omitted.
  # @return [String] presigned GET URL for the uploaded object.
  def upload(file_path:, key:, content_type: nil)
    resolved_content_type = content_type || content_type_for(file_path)
    File.open(file_path, "rb") do |file|
      client.put_object(bucket: @bucket, key: key, body: file, content_type: resolved_content_type)
    end
    signed_url(key)
  rescue Aws::S3::Errors::ServiceError => e
    raise StorageError, "S3 upload failed: #{e.message}"
  end

  # Generates a presigned GET URL for an existing object.
  #
  # @param key [String] object key.
  # @return [String] presigned GET URL.
  def signed_url(key)
    presigner.presigned_url(
      :get_object,
      bucket: @bucket,
      key: key,
      expires_in: url_ttl.to_i
    )
  end

  # Deletes a single object. Returns silently when the object does not exist.
  #
  # @param key [String] object key.
  def delete(key)
    client.delete_object(bucket: @bucket, key: key)
  rescue Aws::S3::Errors::ServiceError => e
    raise StorageError, "S3 delete failed: #{e.message}"
  end

  # Deletes every object under a key prefix.
  #
  # @param prefix [String] key prefix to sweep.
  # @return [Integer] number of objects deleted.
  def delete_prefix(prefix)
    deleted = 0
    client.list_objects_v2(bucket: @bucket, prefix: prefix).each_page do |page|
      next if page.contents.empty?

      client.delete_objects(
        bucket: @bucket,
        delete: { objects: page.contents.map { |obj| { key: obj.key } } }
      )
      deleted += page.contents.size
    end
    deleted
  end

  class << self
    # Whether object storage credentials are configured, resolved the same way
    # as an instance (env var then Rails credential).
    #
    # @return [Boolean]
    def configured?
      configured_access_key_id.present? && configured_secret_access_key.present?
    end

    # Resolved bucket name: `SCREENSHOTS_S3_BUCKET`, then the
    # `screenshots.s3.bucket` credential, then the default.
    def configured_bucket
      ENV.fetch("SCREENSHOTS_S3_BUCKET", credentials_dig(:bucket) || DEFAULT_BUCKET)
    end

    # Resolved region: `SCREENSHOTS_S3_REGION`, then the
    # `screenshots.s3.region` credential, then the default.
    def configured_region
      ENV.fetch("SCREENSHOTS_S3_REGION", credentials_dig(:region) || DEFAULT_REGION)
    end

    # Resolved presigned-URL TTL in seconds: `SCREENSHOTS_S3_URL_TTL`, then the
    # `screenshots.s3.url_ttl` credential, then the S3 presigner maximum.
    def configured_url_ttl
      value = ENV["SCREENSHOTS_S3_URL_TTL"] || credentials_dig(:url_ttl)
      return DEFAULT_URL_TTL if value.blank?

      ttl = Integer(value)
      raise ArgumentError, "SCREENSHOTS_S3_URL_TTL must be positive" unless ttl.positive?
      unless ttl <= MAX_URL_TTL
        raise ArgumentError, "SCREENSHOTS_S3_URL_TTL cannot exceed #{MAX_URL_TTL} seconds for S3 presigned URLs"
      end
      ttl
    end

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

  private

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: client)
  end

  def url_ttl
    @url_ttl ||= self.class.configured_url_ttl
  end

  def client_options
    opts = { region: @region }
    access_key_id = self.class.send(:configured_access_key_id)
    secret_access_key = self.class.send(:configured_secret_access_key)
    endpoint = self.class.send(:configured_endpoint)
    opts[:access_key_id] = access_key_id if access_key_id.present?
    opts[:secret_access_key] = secret_access_key if secret_access_key.present?
    opts[:endpoint] = endpoint if endpoint.present?
    opts[:force_path_style] = true if endpoint.present?
    opts
  end

  def content_type_for(file_path)
    Marcel::MimeType.for(name: file_path).presence || DEFAULT_CONTENT_TYPE
  end
end
