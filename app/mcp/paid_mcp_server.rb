# frozen_string_literal: true

class PaidMcpServer
  PROTOCOL_VERSION = "2024-11-05"
  SERVER_NAME = "paid-mcp-server"
  SERVER_VERSION = "0.1.0"
  RATE_LIMIT_MAX = 30
  RATE_LIMIT_PERIOD = 1.minute

  attr_reader :session, :user

  def initialize(session:, user:)
    @session = session
    @user = user
  end

  def handle_request(method:, params: {}, id: nil)
    check_rate_limit! if method == "tools/call"

    result = case method
    when "initialize"
      handle_initialize
    when "tools/list"
      handle_tools_list
    when "tools/call"
      handle_tool_call(params)
    else
      return jsonrpc_error(id:, code: -32601, message: "Method not found: #{method}")
    end

    jsonrpc_response(id:, result:)
  rescue RateLimitExceeded
    jsonrpc_error(id:, code: -32029, message: "Rate limit exceeded: max #{RATE_LIMIT_MAX} tool calls per minute")
  rescue Pundit::NotAuthorizedError
    jsonrpc_error(id:, code: -32600, message: "Not authorized")
  rescue ArgumentError => e
    jsonrpc_error(id:, code: -32602, message: e.message)
  rescue ActiveRecord::RecordNotFound => e
    jsonrpc_error(id:, code: -32602, message: "Record not found: #{e.message}")
  rescue StandardError => e
    Rails.logger.error(message: "mcp.tool_call_failed", error: e.message, session_id: session.id)
    jsonrpc_error(id:, code: -32603, message: "Internal error")
  end

  def tool_definitions
    Tools::Registry.definitions_for(user:, session:)
  end

  def call_tool(name:, arguments:)
    tool_class = Tools::Registry.find(name)
    raise ArgumentError, "Unknown tool: #{name}" unless tool_class

    tool = tool_class.new(user:, session:)
    tool.call(**arguments.symbolize_keys)
  end

  class RateLimitExceeded < StandardError; end

  private

  def handle_initialize
    {
      protocolVersion: PROTOCOL_VERSION,
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      capabilities: { tools: { listChanged: false } }
    }
  end

  def handle_tools_list
    { tools: tool_definitions }
  end

  def handle_tool_call(params)
    name = params["name"] || params[:name]
    arguments = params["arguments"] || params[:arguments] || {}
    raise ArgumentError, "Tool name is required" unless name.present?

    result = call_tool(name:, arguments:)
    { content: [ { type: "text", text: result.to_json } ] }
  end

  def check_rate_limit!
    key = "mcp:rate_limit:#{session.id}"
    count = Rails.cache.increment(key, 1, expires_in: RATE_LIMIT_PERIOD)
    count ||= 1
    raise RateLimitExceeded if count > RATE_LIMIT_MAX
  end

  def jsonrpc_response(id:, result:)
    { jsonrpc: "2.0", id:, result: }
  end

  def jsonrpc_error(id:, code:, message:)
    { jsonrpc: "2.0", id:, error: { code:, message: } }
  end
end
