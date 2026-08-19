# frozen_string_literal: true

module Containers
  class RuntimeImageSelector
    Result = Data.define(
      :requested_image,
      :image,
      :digest,
      :architecture,
      :registry,
      :repository,
      :provenance_reference,
      :immutable
    ) do
      def metadata
        {
          "requested_image" => requested_image,
          "resolved_image" => image,
          "digest" => digest,
          "architecture" => architecture,
          "registry" => registry,
          "repository" => repository,
          "provenance_reference" => provenance_reference,
          "immutable" => immutable
        }
      end

      # Rebuilds a selection from persisted #metadata so a warm-time selection
      # can be reused at claim time without re-resolving against the catalog.
      def self.from_metadata(metadata)
        new(
          requested_image: metadata["requested_image"],
          image: metadata["resolved_image"],
          digest: metadata["digest"],
          architecture: metadata["architecture"],
          registry: metadata["registry"],
          repository: metadata["repository"],
          provenance_reference: metadata["provenance_reference"],
          immutable: metadata["immutable"]
        )
      end
    end

    def self.select(...)
      new(...).select
    end

    def initialize(project: nil, requested_image: nil, environment: Rails.env, catalog: RuntimeImageCatalog.default,
      provenance_reference: nil)
      @project = project
      @requested_image = requested_image
      @environment = environment
      @catalog = catalog
      @provenance_reference = provenance_reference
    end

    def select
      requested = @requested_image.presence || resolve_requested_image
      return mutable_result(requested) unless production_environment?

      identity = @catalog.identity_for(requested_image: requested, provenance_reference: @provenance_reference)
      immutable_result(requested, identity)
    end

    private

    def resolve_requested_image
      return Containers::ImageResolver::BASE_IMAGE unless @project

      Containers::ImageResolver.resolve(@project)
    end

    def production_environment?
      @environment.to_s == "production"
    end

    def mutable_result(requested)
      # @spec IMMUTABLE-IMAGE-003
      Result.new(
        requested_image: requested,
        image: requested,
        digest: nil,
        architecture: nil,
        registry: nil,
        repository: nil,
        provenance_reference: "mutable:#{requested}",
        immutable: false
      )
    end

    def immutable_result(requested, identity)
      # @spec IMMUTABLE-IMAGE-001, IMMUTABLE-IMAGE-004, IMMUTABLE-IMAGE-005
      Result.new(
        requested_image: requested,
        image: identity.image,
        digest: identity.digest,
        architecture: identity.architecture,
        registry: identity.registry,
        repository: identity.repository,
        provenance_reference: identity.reference,
        immutable: true
      )
    end
  end
end
