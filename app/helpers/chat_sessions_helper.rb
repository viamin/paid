# frozen_string_literal: true

module ChatSessionsHelper
  CHAT_SESSION_STATUS_STYLES = {
    "active" => "bg-green-100 text-green-700",
    "idle" => "bg-yellow-100 text-yellow-800",
    "closed" => "bg-gray-100 text-gray-600",
    "archived" => "bg-gray-100 text-gray-600"
  }.freeze

  CHAT_MODE_STYLES = {
    "api" => "bg-blue-100 text-blue-700",
    "workspace" => "bg-indigo-100 text-indigo-700"
  }.freeze

  def chat_session_status_badge(chat_session)
    badge_label(chat_session.status.titleize, CHAT_SESSION_STATUS_STYLES.fetch(chat_session.status, CHAT_SESSION_STATUS_STYLES["archived"]))
  end

  def chat_mode_badge(mode)
    badge_label(mode.to_s.titleize, CHAT_MODE_STYLES.fetch(mode.to_s, CHAT_MODE_STYLES["api"]))
  end

  def chat_container_status_badge(chat_session)
    label =
      if chat_session.mode != "workspace"
        "API"
      elsif chat_session.status == "active" && chat_session.container_id.present?
        "Running"
      elsif chat_session.status == "idle"
        "Idle"
      else
        "Stopped"
      end

    classes =
      case label
      when "Running" then "bg-green-100 text-green-700"
      when "Idle" then "bg-yellow-100 text-yellow-800"
      when "API" then "bg-gray-100 text-gray-600"
      else "bg-gray-100 text-gray-600"
      end

    badge_label(label, classes)
  end

  def chat_session_title(chat_session)
    chat_session.title.presence || chat_session_preview(chat_session)
  end

  def chat_session_preview(chat_session)
    preview_cache[chat_session.id] ||= begin
      content =
        if chat_session.respond_to?(:preview_content)
          chat_session.preview_content
        else
          chat_session.messages
            .where.not(role: "system")
            .where.not(content: [ nil, "" ])
            .order(:created_at)
            .pick(:content)
        end

      content.to_s.tr("\n", " ").truncate(64).presence || "Untitled chat"
    end
  end

  def chat_session_projects(chat_session)
    (chat_session.projects.to_a + [ chat_session.project ].compact).uniq(&:id)
  end

  def chat_session_member_path(chat_session)
    Rails.application.routes.url_helpers.chat_session_path(chat_session)
  end

  def chat_message_bubble_classes(message)
    case message.role
    when "user"
      "ml-auto max-w-3xl rounded-lg rounded-br-sm bg-gray-900 px-4 py-3 text-sm text-white shadow-sm"
    when "assistant"
      "max-w-3xl rounded-lg rounded-bl-sm bg-white px-4 py-3 text-sm text-gray-900 shadow-sm ring-1 ring-gray-200"
    when "tool"
      "max-w-3xl rounded-lg border border-dashed border-blue-200 bg-blue-50 px-4 py-3 text-sm text-gray-800"
    else
      "mx-auto max-w-2xl rounded-md bg-white px-4 py-2 text-center text-xs font-medium text-gray-500 ring-1 ring-gray-200"
    end
  end

  def chat_message_wrapper_classes(message)
    return "flex justify-end" if message.role == "user"
    return "flex justify-center" if message.role == "system"

    "flex justify-start"
  end

  def chat_message_label(message)
    case message.role
    when "assistant" then message.model.presence || "Assistant"
    when "user" then message.chat_session.created_by&.name.presence || message.chat_session.created_by&.email.presence || "You"
    when "tool" then message.tool_name.presence || "Tool"
    else "System"
    end
  end

  def chat_message_role_badge(message)
    classes =
      case message.role
      when "assistant" then "bg-gray-100 text-gray-600"
      when "user" then "bg-gray-800 text-gray-100"
      when "tool" then "bg-blue-100 text-blue-700"
      else "bg-gray-100 text-gray-500"
      end

    badge_label(message.role.titleize, classes)
  end

  def chat_tool_payload(value)
    return if value.blank?
    return value if value.is_a?(Hash) || value.is_a?(Array)

    JSON.parse(value)
  rescue JSON::ParserError
    value
  end

  CHAT_TOOL_STATUS_BADGES = {
    "pending" => "bg-amber-100 text-amber-800",
    "approved" => "bg-green-100 text-green-700",
    "denied" => "bg-red-100 text-red-700"
  }.freeze

  def chat_tool_status_label(message)
    case message.tool_status
    when "pending" then "pending approval"
    when "approved" then "approved"
    when "denied" then "denied"
    else message.role == "tool" ? "result" : "args"
    end
  end

  def chat_tool_status_classes(message)
    CHAT_TOOL_STATUS_BADGES.fetch(message.tool_status, message.role == "tool" ? "bg-blue-100 text-blue-700" : "bg-blue-100 text-blue-700")
  end

  def pretty_chat_tool_payload(value)
    payload = chat_tool_payload(value)
    return payload if payload.is_a?(String)

    JSON.pretty_generate(payload)
  end

  def chat_popup_available?
    user_signed_in? && controller_path != "chat_sessions"
  end

  def current_chat_popup_context
    context = {
      "url" => request.original_url,
      "path" => request.fullpath,
      "page_title" => content_for(:title).presence || "Paid",
      "controller" => controller_path,
      "action" => action_name
    }

    project = current_chat_popup_project
    return context unless project

    context.merge(
      "project_id" => project.id,
      "project_name" => project.name,
      "project_full_name" => project.full_name
    )
  end

  def current_chat_popup_project
    return @project if defined?(@project) && @project.is_a?(Project)

    nil
  end

  private

  def preview_cache
    @preview_cache ||= {}
  end

  def badge_label(label, classes)
    tag.span(label, class: "inline-flex items-center rounded-full px-2 py-1 text-xs font-medium #{classes}")
  end
end
