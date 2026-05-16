# frozen_string_literal: true

require "docker-api"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

module Knowledge
  class EmbeddingRunner
    class Error < StandardError; end
    class ContainerError < Error; end
    class TimeoutError < ContainerError; end

    CONTAINER_DEFAULTS = {
      image: "paid-agent:latest",
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
      @input_dir = nil
    end

    def self.available?
      Containers.backend.ping == "OK"
    rescue Excon::Error, Docker::Error::DockerError
      false
    end

    def generate(texts:, provider:, model:, dimensions:, timeout: CONTAINER_DEFAULTS[:timeout_seconds])
      ensure_container!
      write_input_file(texts)

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
      cleanup_input_dir!
      raise
    end

    def cleanup!
      cleanup_container!
      cleanup_input_dir!
    end

    private

    def ensure_container!
      return if @container

      cleanup_input_dir!
      NetworkPolicy.ensure_network!(network: NetworkPolicy::NETWORK_NAME)
      @input_dir = Dir.mktmpdir("paid-embedding-runner-")
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

    def cleanup_input_dir!
      return unless @input_dir

      FileUtils.remove_entry(@input_dir)
      @input_dir = nil
    rescue SystemCallError
      nil
    end

    def write_input_file(texts)
      File.write(File.join(@input_dir, "texts.json"), JSON.generate(texts))
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
      NetworkPolicy.apply_firewall_rules(@container, backend: Containers.backend)
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
        require "net/http"
        require "uri"

        proxy_url = ENV.fetch("PROXY_BASE_URL")
        run_id = ENV.fetch("KNOWLEDGE_RUN_ID")
        token = ENV.fetch("PROXY_TOKEN")
        provider = ENV.fetch("EMBEDDING_PROVIDER")
        model = ENV.fetch("EMBEDDING_MODEL")
        dimensions = Integer(ENV.fetch("EMBEDDING_DIMENSIONS"))
        timeout = Integer(ENV.fetch("EMBEDDING_TIMEOUT", "120"))
        input_path = ENV.fetch("INPUT_PATH")

        texts = JSON.parse(File.read(input_path))
        uri = URI("#{proxy_url}/api/proxy/openai/v1/embeddings")
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 10
        http.read_timeout = timeout

        req = Net::HTTP::Post.new(uri.path)
        req["Authorization"] = "Bearer paid-knowledge-run:#{run_id}:#{token}"
        req["Content-Type"] = "application/json"
        req["X-Paid-Knowledge-Provider"] = provider
        req.body = {
          input: texts,
          model: model,
          dimensions: dimensions
        }.to_json

        res = http.request(req)
        unless res.is_a?(Net::HTTPSuccess)
          $stderr.puts("Proxy error: #{res.code} #{res.body&.slice(0, 500)}")
          exit(1)
        end

        $stdout.print(res.body)
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
            "/tmp" => "size=#{64 * 1024 * 1024},mode=1777"
          },
          "NetworkMode" => NetworkPolicy::NETWORK_NAME,
          "Binds" => [ "#{@input_dir}:/paid-input:ro" ]
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
