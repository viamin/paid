# frozen_string_literal: true

require "docker-api"
require "base64"

module Knowledge
  # Runs LLM calls inside an isolated Docker container that authenticates
  # to the secrets proxy via a KnowledgeRun proxy token. No API keys are
  # exposed inside the container — the proxy injects them server-side.
  #
  # Used by Knowledge::Decisions::Draft to containerize decision drafting.
  #
  # @example
  #   runner = Knowledge::AnalysisRunner.new(project: project, knowledge_run: knowledge_run)
  #   runner.with_container do |r|
  #     output = r.call_llm(prompt, provider: "claude", model: "claude-sonnet-4-6")
  #   end
  class AnalysisRunner
    class Error < StandardError; end
    class ContainerError < Error; end
    class TimeoutError < ContainerError; end

    CONTAINER_DEFAULTS = {
      image: "paid-agent:latest",
      memory_bytes: 256 * 1024 * 1024,  # 256MB
      cpu_quota: 100_000,                # 1 CPU
      pids_limit: 100,
      timeout_seconds: 60,
      network_mode: "bridge"             # needs proxy access
    }.freeze

    # Default models per API service type, used when caller does not specify one.
    DEFAULT_MODELS = {
      "anthropic" => "claude-sonnet-4-6",
      "openai" => "gpt-4o"
    }.freeze

    # API service types supported for containerized LLM calls.
    SUPPORTED_API_TYPES = %w[anthropic openai].freeze

    attr_reader :project, :knowledge_run

    def initialize(project:, knowledge_run:)
      @project = project
      @knowledge_run = knowledge_run
      @container = nil
    end

    # Returns true when Docker is available for containerized execution.
    def self.available?
      Containers.backend.ping == "OK"
    rescue Excon::Error, Docker::Error::DockerError
      false
    end

    # Returns true when the given provider can be executed in a container.
    def self.supported_provider?(provider)
      api_type = ProviderSupport.api_service_type_for(provider.to_s)
      SUPPORTED_API_TYPES.include?(api_type)
    end

    # Provisions a container, yields self for LLM calls, then cleans up.
    #
    # @yield [AnalysisRunner] the runner with a provisioned container
    def with_container
      provision!
      yield self
    ensure
      cleanup!
    end

    # Executes an LLM call inside the container via the secrets proxy.
    # Returns the raw text output from the LLM response.
    #
    # @param prompt [String] the prompt to send
    # @param provider [String] app-level provider key (e.g. "claude", "codex")
    # @param model [String, nil] model identifier; defaults per API type
    # @param timeout [Integer] timeout in seconds
    # @return [String] raw LLM text output
    # @raise [ContainerError] on execution failure
    # @raise [TimeoutError] on timeout
    def call_llm(prompt, provider:, model: nil, timeout: CONTAINER_DEFAULTS[:timeout_seconds])
      raise ContainerError, "Container not provisioned" unless @container

      api_type = ProviderSupport.api_service_type_for(provider.to_s)
      raise ContainerError, "Unsupported API type for provider: #{provider}" unless SUPPORTED_API_TYPES.include?(api_type)

      effective_model = model || DEFAULT_MODELS.fetch(api_type)
      env = llm_env(api_type: api_type, model: effective_model, prompt: prompt, timeout: timeout)
      script = llm_script(api_type: api_type)

      execute([ "ruby", "-e", script ], timeout: timeout, env: env)
    end

    private

    def provision!
      log("provision.start")
      @container = Containers.backend.create_container(container_config)
      Containers.backend.start_container(@container)
      log("provision.success", container_id: @container.id)
    rescue Docker::Error::DockerError => e
      cleanup!
      raise ContainerError, "Failed to provision analysis container: #{e.message}"
    end

    def cleanup!
      return unless @container

      log("cleanup.start", container_id: @container.id)
      begin
        Containers.backend.stop_container(@container, timeout: 5)
      rescue Docker::Error::DockerError
        # Container may already be stopped
      end
      begin
        Containers.backend.delete_container(@container, force: true)
      rescue Docker::Error::DockerError
        # Container may already be removed
      end
      @container = nil
      log("cleanup.success")
    end

    def execute(cmd, timeout:, env:)
      exec_options = { wait: timeout }
      exec_options[:Env] = env.map { |k, v| "#{k}=#{v}" }

      mutex = Mutex.new
      exec_completed = false
      timed_out = false

      watchdog = start_watchdog(timeout) do
        mutex.synchronize do
          unless exec_completed
            timed_out = true
            true
          end
        end
      end

      begin
        result = Containers.backend.exec_in_container(@container, cmd, **exec_options)
      rescue Docker::Error::DockerError => e
        raise TimeoutError, "LLM call timed out after #{timeout}s" if mutex.synchronize { timed_out }
        raise ContainerError, "Container execution failed: #{e.message}"
      ensure
        mutex.synchronize { exec_completed = true }
        stop_watchdog(watchdog)
      end

      raise TimeoutError, "LLM call timed out after #{timeout}s" if mutex.synchronize { timed_out }

      stdout = Array(result[0]).join
      stderr = Array(result[1]).join
      exit_code = result[2]

      unless exit_code == 0
        raise ContainerError, "LLM call failed (exit #{exit_code}): #{stderr.first(500)}"
      end

      stdout.strip
    end

    def llm_env(api_type:, model:, prompt:, timeout:)
      {
        "PROXY_BASE_URL" => proxy_base_url,
        "KNOWLEDGE_RUN_ID" => knowledge_run.id.to_s,
        "PROXY_TOKEN" => knowledge_run.ensure_proxy_token!,
        "PROMPT_B64" => Base64.strict_encode64(prompt),
        "LLM_MODEL" => model,
        "LLM_TIMEOUT" => timeout.to_s,
        "API_SERVICE_TYPE" => api_type
      }
    end

    # Generates a minimal Ruby script for the container to call the proxy.
    # Uses only stdlib (net/http, json, base64, uri).
    def llm_script(api_type:)
      case api_type
      when "anthropic" then anthropic_script
      when "openai" then openai_script
      else raise ContainerError, "Unsupported API type: #{api_type}"
      end
    end

    def anthropic_script
      <<~'RUBY'
        require "net/http"
        require "json"
        require "base64"
        require "uri"

        proxy_url   = ENV.fetch("PROXY_BASE_URL")
        run_id      = ENV.fetch("KNOWLEDGE_RUN_ID")
        token       = ENV.fetch("PROXY_TOKEN")
        prompt      = Base64.decode64(ENV.fetch("PROMPT_B64"))
        model       = ENV.fetch("LLM_MODEL")
        timeout     = Integer(ENV.fetch("LLM_TIMEOUT", "30"))

        uri = URI("#{proxy_url}/api/proxy/anthropic/v1/messages")
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 10
        http.read_timeout = timeout

        body = {
          model: model,
          max_tokens: 4096,
          messages: [{ role: "user", content: prompt }]
        }

        req = Net::HTTP::Post.new(uri.path)
        req["Content-Type"] = "application/json"
        req["X-Knowledge-Run-Id"] = run_id
        req["X-Proxy-Token"] = token
        req["anthropic-version"] = "2023-06-01"
        req.body = body.to_json

        res = http.request(req)
        unless res.is_a?(Net::HTTPSuccess)
          $stderr.puts("Proxy error: #{res.code} #{res.body&.slice(0, 500)}")
          exit(1)
        end

        text = JSON.parse(res.body).dig("content", 0, "text") || ""
        $stdout.print(text)
      RUBY
    end

    def openai_script
      <<~'RUBY'
        require "net/http"
        require "json"
        require "base64"
        require "uri"

        proxy_url   = ENV.fetch("PROXY_BASE_URL")
        run_id      = ENV.fetch("KNOWLEDGE_RUN_ID")
        token       = ENV.fetch("PROXY_TOKEN")
        prompt      = Base64.decode64(ENV.fetch("PROMPT_B64"))
        model       = ENV.fetch("LLM_MODEL")
        timeout     = Integer(ENV.fetch("LLM_TIMEOUT", "30"))

        uri = URI("#{proxy_url}/api/proxy/openai/v1/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 10
        http.read_timeout = timeout

        body = {
          model: model,
          max_tokens: 4096,
          messages: [{ role: "user", content: prompt }]
        }

        req = Net::HTTP::Post.new(uri.path)
        req["Content-Type"] = "application/json"
        req["Authorization"] = "Bearer paid-knowledge-run:#{run_id}:#{token}"
        req.body = body.to_json

        res = http.request(req)
        unless res.is_a?(Net::HTTPSuccess)
          $stderr.puts("Proxy error: #{res.code} #{res.body&.slice(0, 500)}")
          exit(1)
        end

        text = JSON.parse(res.body).dig("choices", 0, "message", "content") || ""
        $stdout.print(text)
      RUBY
    end

    def container_config
      {
        "Image" => CONTAINER_DEFAULTS[:image],
        "name" => "paid-analysis-#{project.id}-#{SecureRandom.hex(4)}",
        "User" => "agent",
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
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
          "NetworkMode" => CONTAINER_DEFAULTS[:network_mode]
        },
        "Env" => [
          "HOME=/home/agent",
          "PROJECT_ID=#{project.id}"
        ],
        "WorkingDir" => "/home/agent",
        "Labels" => {
          "paid.resource" => "analysis_container",
          "paid.project_id" => project.id.to_s,
          "paid.knowledge_run_id" => knowledge_run.id.to_s
        },
        "Tty" => false,
        "OpenStdin" => false,
        "Cmd" => [ "tail", "-f", "/dev/null" ]
      }
    end

    def proxy_base_url
      proxy_port = Rails.application.config.x.paid_proxy_port
      "http://paid-proxy:#{proxy_port}"
    end

    def start_watchdog(timeout)
      Thread.new do
        sleep(timeout)
        should_stop = yield
        next unless should_stop

        begin
          Containers.backend.stop_container(@container, timeout: 0) if @container
        rescue Docker::Error::DockerError
          # Container may already be stopped
        end
      end
    end

    def stop_watchdog(watchdog)
      return unless watchdog&.alive?

      watchdog.kill
      watchdog.join(1)
    end

    def log(event, **metadata)
      Rails.logger.info(
        message: "knowledge.analysis_runner.#{event}",
        project_id: project.id,
        knowledge_run_id: knowledge_run.id,
        **metadata
      )
    end
  end
end
