# frozen_string_literal: true

module Containers
  # Removes unused images and aged build cache from the local Docker daemon.
  # The daemon's `Id` values are external input to a destructive request, so only
  # canonical `sha256:<64 hex>` identities ever reach a request path.
  class PruneDockerDisk
    RETENTION = 7.days
    IMAGE_ID_FORMAT = /\Asha256:[0-9a-f]{64}\z/
    CACHE_READ_TIMEOUT = 15.minutes
    PROTECTED_REPO_PREFIXES = [ "paid-agent:", "paid-agent-build:" ].freeze

    def initialize(protected_references:, connection: Docker.connection)
      @connection = connection
      @protected_references = protected_references
    end

    # @spec DOCKER-DISK-CLEANUP-001 DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-003 DOCKER-DISK-CLEANUP-004
    def call
      raise ArgumentError, "Docker disk cleanup requires a local Unix socket" unless connection.options[:socket].present?

      remove_expired_images.merge(cache_bytes_reclaimed: prune_build_cache)
    end

    private

    attr_reader :connection, :protected_references

    def remove_expired_images
      images = JSON.parse(connection.get("/images/json"))
      retained_ids = protected_image_ids | container_image_ids
      cutoff = RETENTION.ago.to_i
      removed = images.select do |image|
        eligible?(image, cutoff, retained_ids) && remove_image(image.fetch("Id"))
      end
      result = {
        images_removed: removed.size,
        image_bytes_estimate: removed.sum { |image| image.fetch("Size", 0).to_i }
      }
      # Logged before cache pruning so a cache failure keeps the image-phase evidence.
      Rails.logger.info(message: "container_manager.disk_cleanup_images_complete", **result)
      result
    end

    def prune_build_cache
      filters = { all: true, filters: { until: [ "#{RETENTION.in_hours.to_i}h" ] }.to_json }
      JSON.parse(connection.post("/build/prune", filters, read_timeout: CACHE_READ_TIMEOUT.to_i)).fetch("SpaceReclaimed")
    end

    def protected_image_ids
      protected_references.filter_map do |reference|
        JSON.parse(connection.get("/images/#{reference}/json")).fetch("Id")
      rescue Docker::Error::NotFoundError
        nil
      end.to_set
    end

    def container_image_ids
      JSON.parse(connection.get("/containers/json", all: true)).pluck("ImageID").to_set
    end

    def eligible?(image, cutoff, retained_ids)
      id = image["Id"]
      created = image["Created"]
      canonical_id?(id) &&
        created.is_a?(Integer) && created.positive? && created < cutoff &&
        !retained_ids.include?(id) &&
        Array(image["RepoTags"]).none? { |tag| tag.to_s.start_with?(*PROTECTED_REPO_PREFIXES) }
    end

    def canonical_id?(id)
      id.is_a?(String) && id.match?(IMAGE_ID_FORMAT)
    end

    def remove_image(id)
      connection.delete(image_delete_path(id), force: false, noprune: true)
      true
    rescue Docker::Error::ConflictError, Docker::Error::NotFoundError => e
      Rails.logger.warn(
        message: "container_manager.disk_cleanup_image_delete_skipped",
        image_id: id,
        error_class: e.class.name,
        error: e.message
      )
      false
    end

    # `eligible?` admits canonical digests only, so the interpolated value cannot
    # alter the request path; the guard keeps that invariant at the interpolation.
    def image_delete_path(id)
      raise ArgumentError, "Refusing to delete image with non-canonical id #{id.inspect}" unless canonical_id?(id)

      "/images/#{id}"
    end
  end
end
