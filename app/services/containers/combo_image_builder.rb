# frozen_string_literal: true

module Containers
  # Builds the combo agent images that {ImageResolver} names (RDR-046 Phase 3 /
  # #3613).
  #
  # Language layers live in +docker/agent/languages/<token>.dockerfile+. Each
  # layer is written as +ARG BASE_IMAGE+ + +FROM ${BASE_IMAGE}+ plus a pinned,
  # checksum-verified toolchain install, so the builder can compose any combo:
  # single-extended-runtime combos build one layer tagged with the resolved
  # combo tag; multi-extended combos build a chain where every layer is
  # tagged — the final layer with the resolved combo tag, intermediate layers
  # with a private +paid-agent-build:*+ tag — and each layer builds FROM the
  # previous layer's *tag*, never its build id. Backends that build on
  # multiple hosts (e.g. swarm) run each layer's build independently per
  # node and only the tag, not the id, is guaranteed to resolve consistently
  # wherever the next layer happens to build. Intermediate tags are untagged
  # immediately once the whole chain succeeds — they exist only to give the
  # next layer a FROM target, and Docker's content-addressed layer store
  # keeps the shared layers alive under the final tag regardless.
  #
  # Built images carry labels recording the base image digest they were built
  # against, when they were built, and which extended runtime each layer added.
  # A combo whose recorded base digest no longer matches the current base image
  # is stale and is rebuilt on its next use, so a base-image patch cascades to
  # combos (POLYGLOT-TEST-009).
  #
  # Failures are loud: unknown tokens, base-only tags, missing base image,
  # missing layer Dockerfile, and failed builds all raise specific errors. The
  # caller ({Provision}) converts them into provision failures — never a
  # silent fallback to the base image (POLYGLOT-TEST-008).
  #
  # Non-Paid image references (explicit overrides, immutable catalog digests
  # from RDR-059) return +nil+ from +.ensure_available+ untouched — the builder
  # only owns +paid-agent:*+ tags.
  class ComboImageBuilder
    Result = Data.define(:image, :status, :duration_ms) do
      def built?
        %i[built rebuilt].include?(status)
      end
    end

    class Error < StandardError; end

    # The tag names tokens the language-layer matrix cannot produce — unknown
    # runtimes, or a tag with no extended runtime layer at all.
    class UnbuildableImageError < Error; end

    # The Docker build itself failed (network, checksum, apt, ...).
    class BuildError < Error; end

    # Combo layers compose on the base image; without it there is nothing to
    # build from.
    class MissingBaseImageError < BuildError; end

    LABEL_NAMESPACE = "dev.paid.agent-image"
    BASE_DIGEST_LABEL = "#{LABEL_NAMESPACE}.base-digest"
    BUILT_AT_LABEL = "#{LABEL_NAMESPACE}.built-at"
    LANGUAGES_LABEL = "#{LABEL_NAMESPACE}.languages"

    # Tag namespace for intermediate chain layers. Deliberately outside the
    # +paid-agent:+ namespace so neither {ImageResolver.combo?} nor
    # {.combo_images} ever mistakes an in-progress layer for a resolvable
    # combo tag.
    INTERMEDIATE_TAG_PREFIX = "paid-agent-build"

    BUILD_OUTPUT_TAIL_LINES = 40

    ADVISORY_LOCK_SQL = "SELECT pg_advisory_lock($1, $2)".freeze
    ADVISORY_UNLOCK_SQL = "SELECT pg_advisory_unlock($1, $2)".freeze
    LOCK_NAMESPACE = 1_357_180_005

    class << self
      # The language layer Dockerfiles live in the repository, next to the
      # base agent image Dockerfile.
      def languages_dir
        Rails.root.join("docker/agent/languages")
      end

      # Ensures the given image reference exists on the backend, building it
      # from the language layers when it is a missing or stale paid-agent
      # combo tag.
      #
      # @return [Result, nil] Result describing an ensured combo image, or
      #   +nil+ when the reference is not a combo tag this builder owns.
      # @spec POLYGLOT-TEST-007
      def ensure_available(image, backend: Containers.backend)
        tokens = parse_combo_tokens(image)
        return unless tokens

        new(backend: backend).ensure_available(image, tokens)
      end

      # Rebuilds a combo tag even when it already exists and is current. Used
      # by the cascade task after a base-image bump and by operators.
      #
      # @spec POLYGLOT-TEST-009
      def force_rebuild(image, backend: Containers.backend)
        tokens = parse_combo_tokens(image)
        return unless tokens

        new(backend: backend).build(image, tokens, nocache: true)
      end

      # Lists the paid-agent combo images present on the backend with their
      # labels. Used by the cascade task and the stale-image cleanup job, both
      # of which feed every entry straight back into a build or prune
      # decision — so the list is restricted to tags this builder can actually
      # build ({.buildable?}), not the whole +paid-agent:+ namespace. Other
      # tags in that namespace exist on real backends (the documented
      # +paid-agent:ruby-node-python+ base alias, an operator's
      # +IMAGE_TAG=v1.0.0+ build) and can never be composed from the language
      # matrix; enumerating them would only make the cascade task report
      # failures for images it was never meant to own.
      #
      # @return [Array<Hash>] one entry per buildable combo tag with :image,
      #   :id, and :labels keys.
      def combo_images(backend: Containers.backend)
        backend.list_images.flat_map do |docker_image|
          (docker_image.info["RepoTags"] || []).filter_map do |tag|
            next unless buildable?(tag)

            { image: tag, id: docker_image.id, labels: docker_image.info["Labels"] || {} }
          end
        end
      end

      # True when the reference is a combo tag this builder can compose: it
      # parses under the resolver's tag grammar and names at least one
      # extended runtime layer. Unlike {.parse_combo_tokens}, which is the
      # loud path for a tag a caller demanded, this is the quiet predicate for
      # enumerating what is already on a backend.
      def buildable?(image)
        parse_combo_tokens(image).present?
      rescue UnbuildableImageError
        false
      end

      # Normalizes resolver grammar violations into the builder's
      # UnbuildableImageError contract.
      def parse_combo_tokens(image)
        tokens = ImageResolver.combo_tokens(image)
        return unless tokens

        unless (ImageResolver::EXTENDED_LANGUAGES & tokens).any?
          raise UnbuildableImageError,
                "Image #{image.inspect} carries no extended runtime layer; " \
                "only combo tags with at least one of #{ImageResolver::EXTENDED_LANGUAGES.join(", ")} are buildable"
        end

        tokens
      rescue ImageResolver::UnsupportedRuntimeError => e
        raise UnbuildableImageError, e.message
      end
    end

    attr_reader :backend

    def initialize(backend: Containers.backend)
      @backend = backend
    end

    # @spec POLYGLOT-TEST-007
    # @spec POLYGLOT-TEST-009
    def ensure_available(image, tokens)
      with_build_lock(image) do
        status = current_status(image)
        return Result.new(image: image, status: :existing, duration_ms: 0) if status == :current

        build(image, tokens).with(
          status: status == :missing ? :built : :rebuilt
        )
      end
    end

    def build(image, tokens, nocache: false)
      layers = ImageResolver::EXTENDED_LANGUAGES & tokens
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      log(:info, "agent_image.build.start", image: image, layers: layers, nocache: nocache)
      intermediate_tags = []
      digest = base_image_digest
      from = ImageResolver::BASE_IMAGE
      layers.each_with_index do |token, index|
        tag = index == layers.size - 1 ? image : intermediate_tag(image, index)
        build_layer(token, from: from, tag: tag, base_digest: digest, nocache: nocache)
        intermediate_tags << tag unless tag == image
        from = tag
      end
      untag_intermediates(intermediate_tags)
      duration_ms = elapsed_ms(started)
      log(:info, "agent_image.build.success", image: image, layers: layers, duration_ms: duration_ms)
      Result.new(image: image, status: :built, duration_ms: duration_ms)
    rescue Docker::Error::DockerError, Error => e
      log(:error, "agent_image.build.failed", image: image, error: "#{e.class}: #{e.message}", duration_ms: elapsed_ms(started))
      untag_intermediates(intermediate_tags)
      raise
    end

    private

    # @return [Symbol] :missing, :stale, or :current
    def current_status(image)
      labels = image_label_sets(image)
      return :missing if labels.empty?

      labels.all? { |label_set| label_set[BASE_DIGEST_LABEL] == base_image_digest } ? :current : :stale
    end

    def image_label_sets(image)
      backend.image_label_sets(image)
    rescue Docker::Error::NotFoundError
      []
    end

    def base_image_digest
      @base_image_digest ||= backend.get_image(ImageResolver::BASE_IMAGE).id
    rescue Docker::Error::NotFoundError
      raise MissingBaseImageError,
            "Base agent image #{ImageResolver::BASE_IMAGE} is not present on backend #{backend.identifier}, " \
            "so combo images cannot be built. Build it first with scripts/build-agent-image.sh"
    end

    # Builds a single language layer, tagging it so the next layer (or the
    # caller, for the final layer) can chain FROM it by tag. The build's
    # return value is intentionally ignored: on multi-node backends it is one
    # image per node, and no single id among them resolves everywhere the
    # next layer might build — only the tag every node applied locally does.
    def build_layer(token, from:, tag:, base_digest:, nocache:)
      dockerfile = File.read(File.join(self.class.languages_dir, "#{token}.dockerfile"))
      labels = {
        BASE_DIGEST_LABEL => base_digest,
        BUILT_AT_LABEL => Time.current.utc.iso8601,
        LANGUAGES_LABEL => token
      }
      opts = { t: tag, buildargs: { "BASE_IMAGE" => from }.to_json, labels: labels.to_json }
      opts[:nocache] = "1" if nocache

      backend.build_image(dockerfile, opts) { |chunk| capture_build_output(chunk) }
    rescue Errno::ENOENT => e
      raise UnbuildableImageError, "No language layer Dockerfile for #{token.inspect} (#{e.class}: #{e.message})"
    rescue Docker::Error::DockerError => e
      raise BuildError, build_failure_message(token, tag, e)
    end

    def intermediate_tag(image, index)
      "#{INTERMEDIATE_TAG_PREFIX}:#{image.split(":", 2).last}--layer#{index}"
    end

    # Intermediate tags exist only to give the next layer a stable FROM
    # target; once the chain finishes, the final layer's image already holds
    # every layer's content (Docker's content-addressed layer store keeps
    # them alive independent of the tag), so the private tags are dropped
    # immediately rather than left to accumulate. Best-effort: a failed
    # untag leaves an orphaned `paid-agent-build:*` tag but never fails the
    # build the caller is waiting on.
    def untag_intermediates(tags)
      tags.each do |tag|
        backend.delete_image(tag)
      rescue Docker::Error::DockerError => e
        log(:warn, "agent_image.build.intermediate_untag_failed", tag: tag, error: "#{e.class}: #{e.message}")
      end
    end

    # Bounded capture of the streamed build output for failure messages —
    # only the tail is retained.
    def capture_build_output(chunk)
      @build_output_tail ||= []
      lines = chunk.to_s.lines.map(&:strip)
      return if lines.empty?

      @build_output_tail.concat(lines)
      excess = @build_output_tail.size - BUILD_OUTPUT_TAIL_LINES
      @build_output_tail.shift(excess) if excess.positive?
    end

    def build_failure_message(token, tag, error)
      details = Array(@build_output_tail).last(BUILD_OUTPUT_TAIL_LINES).join("\n")
      message = +"Failed to build agent image layer #{token.inspect}"
      message << " for #{tag}" if tag
      message << ": #{error.message}"
      message << "\nBuild output tail:\n#{details}" if details.present?
      message
    end

    # Serializes builds of the same image tag across every process that
    # shares this Rails app's Postgres database — not just this host. A file
    # lock only coordinates processes on one machine; for `remote_docker` and
    # `swarm` backends, multiple app/GoodJob instances can build the same
    # combo tag concurrently against the same backend, and because the
    # intermediate tag name is deterministic
    # (`paid-agent-build:<combo>--layer0`), one build can untag it while
    # another is still using it as `FROM`. A Postgres advisory lock, keyed by
    # image tag, is visible to every process regardless of which host or
    # backend it is building against. The existence/staleness check runs
    # inside the lock, so a process that waited on the lock sees the
    # winner's image and skips its own duplicate build.
    def with_build_lock(image)
      lock_key = advisory_lock_key(image)
      raw_connection = ActiveRecord::Base.connection.raw_connection
      raw_connection.exec_params(ADVISORY_LOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
      @build_output_tail = nil
      yield
    ensure
      @build_output_tail = nil
      raw_connection&.exec_params(ADVISORY_UNLOCK_SQL, [ LOCK_NAMESPACE, lock_key ])
    end

    def advisory_lock_key(image)
      Digest::SHA256.digest(image).unpack1("l>")
    end

    def elapsed_ms(started)
      return 0 unless started

      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    def log(level, message, **metadata)
      Rails.logger.public_send(level, { message: message }.merge(metadata))
    end
  end
end
