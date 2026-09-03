# frozen_string_literal: true

require "docker-api"
require "json"
require "securerandom"
require "rubygems/package"
require "stringio"

module Knowledge
  class EmbeddingRunner
    class Error < StandardError; end
    class ContainerError < Error; end
    class TimeoutError < ContainerError; end

    # Input is streamed into the container as a tar archive (see
    # #stream_input_to_container!) rather than bind-mounted from a host temp
    # dir: a temp dir created by this process is not visible to the Docker
    # daemon in DooD deployments (the daemon runs outside this container), so
    # a host bind mount here silently mounts an empty directory and every run
    # fails reading /paid-input/texts.json (RDR-054).
    INPUT_TMPFS_SIZE = 8 * 1024 * 1024

    CONTAINER_DEFAULTS = {
      # Embedding runs never need the project's own runtime — always the base
      # image (RDR-046 / POLYGLOT-TEST-004).
      image: Containers::ImageResolver::BASE_IMAGE,
      memory_bytes: 256 * 1024 * 1024,
      cpu_quota: 100_000,
      pids_limit: 100,
      timeout_seconds: 120
    }.freeze

    attr_reader :project, :knowledge_run

    def initialize(project:, knowledge_run:)
      @project = project
      @knowledge_run = knowledge_run
      @container = nil
    end

    def self.available?
      Containers.backend.ping == "OK"
    rescue Excon::Error, Docker::Error::DockerError
      false
    end

    def generate(texts:, provider:, model:, dimensions:, timeout: CONTAINER_DEFAULTS[:timeout_seconds])
      ensure_container!
      stream_input_to_container!(texts)

      result = execute(
        [ "ruby", "-e", script ],
        timeout: timeout,
        env: script_env(provider:, model:, dimensions:, timeout:)
      )

      parse_results(result)
    rescue StandardError
      # After any failure the container may be in a bad state.
      # Reset so the next provider attempt reprovisions a fresh container.
      cleanup_container!
      raise
    end

    def cleanup!
      cleanup_container!
    end

    private

    def ensure_container!
      return if @container

      ExecutionRunners::LocalDockerRunner.ensure_agent_network!(backend: Containers.backend)
      @container = Containers.backend.create_container(container_config)
      Containers.backend.start_container(@container)
      apply_network_restrictions!
    rescue Docker::Error::DockerError => e
      cleanup!
      raise ContainerError, "Failed to provision embedding container: #{e.message}"
    rescue NetworkPolicy::Error => e
      cleanup!
      raise ContainerError, "Failed to provision embedding container: #{e.message}"
    end

    def cleanup_container!
      return unless @container

      Containers.backend.stop_container(@container, timeout: 5)
    rescue Docker::Error::DockerError
      nil
    ensure
      begin
        Containers.backend.delete_container(@container, force: true) if @container
      rescue Docker::Error::DockerError
        nil
      end
      @container = nil
    end

    # Streams texts.json into the container's /paid-input tmpfs mount as a
    # tar archive over the Docker API socket, so no host filesystem path
    # ever needs to be visible to the Docker daemon.
    # @spec KNOWLEDGE-CONTAINER-002
    def stream_input_to_container!(texts)
      data = build_input_tar(texts)
      offset = 0

      @container.archive_in_stream("/paid-input") do
        chunk = data.byteslice(offset, 8192).to_s
        offset += chunk.bytesize
        chunk
      end
    rescue Docker::Error::DockerError => e
      raise ContainerError, "Failed to stage embedding input: #{e.message}"
    end

    def build_input_tar(texts)
      json = JSON.generate(texts)
      tar_io = StringIO.new
      Gem::Package::TarWriter.new(tar_io) do |tar|
        tar.add_file_simple("texts.json", 0o644, json.bytesize) { |io| io.write(json) }
      end
      tar_io.string
    end

    def execute(cmd, timeout:, env:)
      exec_options = { wait: timeout }
      exec_options[:Env] = env.map { |key, value| "#{key}=#{value}" }

      mutex = Mutex.new
      exec_completed = false
      timed_out = false

      watchdog = Thread.new do
        sleep(timeout)
        mutex.synchronize do
          next if exec_completed

          timed_out = true
          Containers.backend.stop_container(@container, timeout: 0) if @container
        end
      end

      result = Containers.backend.exec_in_container(@container, cmd, **exec_options)
      raise TimeoutError, "Embedding generation timed out after #{timeout}s" if mutex.synchronize { timed_out }

      stdout = Array(result[0]).join
      stderr = Array(result[1]).join
      exit_code = result[2]
      raise ContainerError, "Embedding generation failed (exit #{exit_code}): #{stderr.first(500)}" unless exit_code.to_i.zero?

      stdout
    rescue Docker::Error::DockerError => e
      raise TimeoutError, "Embedding generation timed out after #{timeout}s" if mutex&.synchronize { timed_out }
      raise ContainerError, "Container execution failed: #{e.message}"
    ensure
      mutex&.synchronize { exec_completed = true }
      watchdog&.kill
      watchdog&.join
    end

    def parse_results(output)
      body = JSON.parse(output)
      Knowledge::Embeddings::Generate.results_from_body(body)
    rescue JSON::ParserError => e
      raise ContainerError, "Failed to parse embedding container output: #{e.message}"
    end

    def apply_network_restrictions!
      ExecutionRunners::LocalDockerRunner.apply_firewall_rules(@container, backend: Containers.backend)
    end

    def script_env(provider:, model:, dimensions:, timeout:)
      {
        "PROXY_BASE_URL" => Containers::ProxyUrl.resolve(backend: Containers.backend, restricted: true),
        "KNOWLEDGE_RUN_ID" => knowledge_run.id.to_s,
        "PROXY_TOKEN" => knowledge_run.ensure_proxy_token!,
        "EMBEDDING_PROVIDER" => provider,
        "EMBEDDING_MODEL" => model,
        "EMBEDDING_DIMENSIONS" => dimensions.to_s,
        "EMBEDDING_TIMEOUT" => timeout.to_s,
        "INPUT_PATH" => "/paid-input/texts.json"
      }
    end

    def script
      <<~'RUBY'
        require "json"
        require "agent_harness"

        module PaidEmbeddingTransportPatch
          PAID_TRANSPORT_ERRORS = [
            EOFError,
            OpenSSL::SSL::SSLError
          ].freeze

          def initialize(base_url:, api_key:, model:, logger: nil, extra_headers: {}, timeout: self.class::DEFAULT_TIMEOUT)
            @paid_extra_headers = extra_headers
            @paid_timeout = timeout
            super(base_url:, api_key:, model:, logger:)
          end

          def embed(inputs:, model: nil, dimensions: nil)
            uri = URI("#{@base_url}/embeddings")
            body = {
              input: inputs,
              model: model || @model
            }
            body[:dimensions] = dimensions if dimensions

            http_response = make_request(uri, body)
            status_code = http_response.code.to_i
            handle_embedding_error_response(http_response, status_code) unless status_code == 200

            JSON.parse(http_response.body)
          rescue *PAID_TRANSPORT_ERRORS => e
            raise AgentHarness::ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
          rescue JSON::ParserError => e
            raise AgentHarness::ProviderError.new(
              "Invalid JSON in embedding API response: #{e.message}",
              original_error: e
            )
          end

          private

          def build_http(uri)
            http = super
            http.read_timeout = @paid_timeout if @paid_timeout
            http
          end

          def build_post_request(uri, body)
            request = super
            @paid_extra_headers.each { |key, value| request[key] = value }
            request
          end

          def handle_embedding_error_response(http_response, status_code)
            headers = http_response.each_header.to_h.transform_keys(&:downcase)
            context = {
              status: status_code,
              headers: headers
            }
            message = embedding_error_message(http_response.body)

            case status_code
            when 401
              raise AgentHarness::AuthenticationError.new(
                "API authentication failed: #{message}",
                provider: :openai_compatible,
                context:
              )
            when 403
              raise AgentHarness::AuthenticationError.new(
                "API access forbidden: #{message}",
                provider: :openai_compatible,
                context:
              )
            when 429
              raise AgentHarness::RateLimitError.new(
                "API rate limit exceeded: #{message}",
                provider: :openai_compatible,
                context:
              )
            when 400
              raise AgentHarness::ProviderError.new("Bad request: #{message}", context:)
            when 500, 502, 503, 504
              raise AgentHarness::ProviderError.new("Server error (#{status_code}): #{message}", context:)
            else
              raise AgentHarness::ProviderError.new("HTTP #{status_code}: #{message}", context:)
            end
          end

          def embedding_error_message(body_string)
            body = JSON.parse(body_string)
            body.dig("error", "message") || body.dig("error", "type") || body_string
          rescue JSON::ParserError
            body_string
          end
        end

        AgentHarness::OpenAICompatibleTransport.prepend(PaidEmbeddingTransportPatch) unless
          AgentHarness::OpenAICompatibleTransport < PaidEmbeddingTransportPatch

        proxy_url = ENV.fetch("PROXY_BASE_URL")
        run_id = ENV.fetch("KNOWLEDGE_RUN_ID")
        token = ENV.fetch("PROXY_TOKEN")
        provider = ENV.fetch("EMBEDDING_PROVIDER")
        model = ENV.fetch("EMBEDDING_MODEL")
        dimensions = Integer(ENV.fetch("EMBEDDING_DIMENSIONS"))
        timeout = Integer(ENV.fetch("EMBEDDING_TIMEOUT", "120"))
        input_path = ENV.fetch("INPUT_PATH")

        texts = JSON.parse(File.read(input_path))
        transport = AgentHarness::OpenAICompatibleTransport.new(
          base_url: "#{proxy_url}/api/proxy/openai/v1",
          api_key: "paid-knowledge-run:#{run_id}:#{token}",
          model: model,
          extra_headers: {
            "X-Paid-Knowledge-Provider" => provider
          },
          timeout: timeout
        )

        body = transport.embed(inputs: texts, model: model, dimensions: dimensions)
        $stdout.print(JSON.generate(body))
      RUBY
    end

    def container_config
      {
        "Image" => CONTAINER_DEFAULTS[:image],
        "name" => "paid-embedding-#{project.id}-#{SecureRandom.hex(4)}",
        "User" => "agent",
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
        "CapAdd" => [ "NET_RAW" ],
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "HostConfig" => {
          "Memory" => CONTAINER_DEFAULTS[:memory_bytes],
          "MemorySwap" => CONTAINER_DEFAULTS[:memory_bytes],
          "CpuPeriod" => 100_000,
          "CpuQuota" => CONTAINER_DEFAULTS[:cpu_quota],
          "PidsLimit" => CONTAINER_DEFAULTS[:pids_limit],
          "Tmpfs" => {
            "/tmp" => "size=#{64 * 1024 * 1024},mode=1777",
            "/paid-input" => "size=#{INPUT_TMPFS_SIZE},mode=1777"
          },
          "NetworkMode" => NetworkPolicy::NETWORK_NAME
        },
        "Env" => [
          "HOME=/home/agent",
          "PROJECT_ID=#{project.id}"
        ],
        "WorkingDir" => "/home/agent",
        "Labels" => {
          "paid.resource" => "embedding_container",
          "paid.project_id" => project.id.to_s,
          "paid.knowledge_run_id" => knowledge_run.id.to_s
        },
        "Tty" => false,
        "OpenStdin" => false,
        "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end
  end
end
