# frozen_string_literal: true

module Containers
  class PruneDockerDisk
    RETENTION = 7.days

    def initialize(protected_references:, connection: Docker.connection)
      @connection = connection
      @protected_references = protected_references
    end

    # @spec DOCKER-DISK-CLEANUP-001 DOCKER-DISK-CLEANUP-002 DOCKER-DISK-CLEANUP-003 DOCKER-DISK-CLEANUP-004
    def call
      raise ArgumentError, "Docker disk cleanup requires a local Unix socket" unless connection.options[:socket].present?

      images = JSON.parse(connection.get("/images/json"))
      protected_ids = protected_image_ids
      used_ids = JSON.parse(connection.get("/containers/json", all: true)).pluck("ImageID").to_set
      retained_ids = protected_ids | used_ids
      cutoff = RETENTION.ago.to_i
      removed = images.select do |image|
        eligible?(image, cutoff, retained_ids) && remove_image(image.fetch("Id"))
      end
      Rails.logger.info(
        message: "container_manager.disk_cleanup_images_complete",
        images_removed: removed.size,
        image_bytes_estimate: removed.sum { |image| image.fetch("Size", 0) }
      )
      cache = JSON.parse(connection.post(
        "/build/prune", { all: true, filters: { until: [ "168h" ] }.to_json }, read_timeout: 15.minutes.to_i
      ))
      {
        images_removed: removed.size,
        image_bytes_estimate: removed.sum { |image| image.fetch("Size", 0) },
        cache_bytes_reclaimed: cache.fetch("SpaceReclaimed")
      }
    end

    private

    attr_reader :connection, :protected_references

    def protected_image_ids
      protected_references.filter_map do |reference|
        JSON.parse(connection.get("/images/#{reference}/json")).fetch("Id")
      rescue Docker::Error::NotFoundError
        nil
      end.to_set
    end

    def eligible?(image, cutoff, retained_ids)
      created = image["Created"]
      created.is_a?(Integer) && created.positive? && created < cutoff &&
        !retained_ids.include?(image.fetch("Id")) &&
        Array(image["RepoTags"]).none? { |tag| tag.start_with?("paid-agent:", "paid-agent-build:") }
    end

    def remove_image(id)
      connection.delete("/images/#{id}", force: false, noprune: true)
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
  end
end
