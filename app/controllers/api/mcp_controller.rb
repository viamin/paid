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

      write_sse_event("endpoint", { url: api_mcp_call_url })

      # Keep connection alive until client disconnects
      loop do
        write_sse_event("ping", { time: Time.current.iso8601 })
        sleep 15
      end
    rescue IOError, ActionController::Live::ClientDisconnected
      # Client disconnected
    ensure
      TenantContext.clear!
      response.stream.close
    end

    # POST /api/mcp/call - JSON-RPC endpoint for MCP tool calls
    def call
      body = parse_request_body
      return render json: jsonrpc_error(nil, -32700, "Parse error"), status: :ok unless body

      server = PaidMcpServer.new(session: @chat_session, user: @current_user)
      result = server.handle_request(
        method: body["method"],
        params: body["params"] || {},
        id: body["id"]
      )

      render json: result, status: :ok
    end

    private

    def authenticate_session!
      token = extract_session_token
      unless token.present?
        render json: { error: "Session token required" }, status: :unauthorized
        return
      end

      @chat_session = ChatSession.find_by(external_id: token)
      unless @chat_session&.status == "active"
        render json: { error: "Invalid or inactive session" }, status: :unauthorized
        return
      end

      @current_user = @chat_session.created_by
      unless @current_user
        render json: { error: "Session has no associated user" }, status: :unauthorized
        return
      end

      TenantContext.apply!(@chat_session.account)
    end

    def teardown_tenant_context
      TenantContext.clear!
    end

    def extract_session_token
      # Check header first, then query param
      request.headers["X-Session-Token"].presence ||
        request.headers["Authorization"]&.delete_prefix("Bearer ")&.presence ||
        params[:session_token]
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
