# frozen_string_literal: true

module Api
  class McpController < ActionController::API
    include ActionController::Live

    before_action :authenticate_session!
    after_action :teardown_tenant_context

    # GET /api/mcp/sse - SSE endpoint for MCP client connections
    def sse
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no"
      subscriber = Mcp::SessionTransport.subscribe(session_id: @chat_session.id)

      write_sse_event("endpoint", { url: api_mcp_call_url })

      loop do
        event = subscriber.pop(timeout: 15)
        if event
          write_sse_event(event.fetch(:event), event.fetch(:data))
        else
          write_sse_event("ping", { time: Time.current.iso8601 })
        end
      end
    rescue IOError, ActionController::Live::ClientDisconnected
      # Client disconnected
    ensure
      Mcp::SessionTransport.unsubscribe(session_id: @chat_session.id, subscriber:) if subscriber
      TenantContext.clear!
      response.stream.close
    end

    # POST /api/mcp/call - JSON-RPC endpoint for MCP tool calls
    def call
      body = parse_request_body
      return render json: jsonrpc_error(nil, -32700, "Parse error"), status: :ok unless body

      server = PaidMcpServer.new(session: @chat_session, user: @current_user, agent_run: @agent_run)
      result = server.handle_request(
        method: body["method"],
        params: body["params"] || {},
        id: body["id"]
      )

      return head :no_content if result.nil?

      render json: result, status: :ok
    end

    private

    def authenticate_session!
      token = extract_session_token
      unless token.present?
        render json: { error: "Session token required" }, status: :unauthorized
        return
      end

      @chat_session, @current_user = TenantContext.with_system_access do
        session = ChatSession.find_by(external_id: token)
        [ session, session&.created_by ]
      end

      unless @chat_session&.status == "active"
        render json: { error: "Invalid or inactive session" }, status: :unauthorized
        return
      end

      unless @current_user
        render json: { error: "Session has no associated user" }, status: :unauthorized
        return
      end

      TenantContext.apply!(@chat_session.account)
      authenticate_agent_run!
    end

    def teardown_tenant_context
      TenantContext.clear!
    end

    def extract_session_token
      request.headers["X-Session-Token"].presence ||
        request.headers["Authorization"]&.delete_prefix("Bearer ")&.presence
    end

    def authenticate_agent_run!
      agent_run_id = request.headers["X-Agent-Run-Id"]
      return unless agent_run_id.present?

      @agent_run = TenantContext.with_system_access do
        AgentRun.includes(project: :account).find_by(id: agent_run_id)
      end
      return reject_agent_run! unless @agent_run&.active? || @agent_run&.claimed?
      return reject_agent_run! unless @agent_run.project.account_id == @chat_session.account_id
      return reject_agent_run! unless @agent_run.initiating_user_id == @current_user.id
      reject_agent_run! unless valid_agent_run_proxy_token?
    end

    def valid_agent_run_proxy_token?
      token = request.headers["X-Proxy-Token"]
      token.present? && ActiveSupport::SecurityUtils.secure_compare(token, @agent_run.ensure_proxy_token!)
    end

    def reject_agent_run!
      render json: { error: "Invalid agent run proxy token" }, status: :forbidden
    end

    def parse_request_body
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      nil
    end

    def write_sse_event(event, data)
      response.stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
    end

    def jsonrpc_error(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end
