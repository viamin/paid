# frozen_string_literal: true

module ChatSessionsHelper
  CHAT_SESSION_STATUS_STYLES = {
    "active" => "bg-emerald-100 text-emerald-700",
    "idle" => "bg-amber-100 text-amber-700",
    "closed" => "bg-slate-100 text-slate-600",
    "archived" => "bg-gray-100 text-gray-600"
  }.freeze

  CHAT_MODE_STYLES = {
    "api" => "bg-sky-100 text-sky-700",
    "workspace" => "bg-fuchsia-100 text-fuchsia-700"
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
      when "Running" then "bg-emerald-100 text-emerald-700"
      when "Idle" then "bg-amber-100 text-amber-700"
      when "API" then "bg-slate-100 text-slate-600"
      else "bg-gray-100 text-gray-600"
      end

    badge_label(label, classes)
  end

  def chat_session_title(chat_session)
    chat_session.title.presence || chat_session_preview(chat_session)
  end

  def chat_session_preview(chat_session)
    preview_cache[chat_session.id] ||= begin
      content = chat_session.messages
        .where.not(role: "system")
        .where.not(content: [ nil, "" ])
        .order(:created_at)
        .pick(:content)

      content.to_s.tr("\n", " ").truncate(64).presence || "Untitled chat"
    end
  end

  def chat_message_bubble_classes(message)
    case message.role
    when "user"
      "ml-auto max-w-3xl rounded-[1.5rem] rounded-br-md bg-slate-900 px-4 py-3 text-sm text-white shadow-sm"
    when "assistant"
      "max-w-3xl rounded-[1.5rem] rounded-bl-md bg-white px-4 py-3 text-sm text-slate-900 shadow-sm ring-1 ring-slate-200"
    when "tool"
      "max-w-3xl rounded-2xl border border-dashed border-cyan-200 bg-cyan-50 px-4 py-3 text-sm text-slate-800"
    else
      "mx-auto max-w-2xl rounded-full bg-white/70 px-4 py-2 text-center text-xs font-medium text-slate-500 ring-1 ring-slate-200"
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
      when "assistant" then "bg-slate-100 text-slate-600"
      when "user" then "bg-slate-800 text-slate-100"
      when "tool" then "bg-cyan-100 text-cyan-700"
      else "bg-white/70 text-slate-500"
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

  def pretty_chat_tool_payload(value)
    payload = chat_tool_payload(value)
    return payload if payload.is_a?(String)

    JSON.pretty_generate(payload)
  end

  private

  def preview_cache
    @preview_cache ||= {}
  end

  def badge_label(label, classes)
    tag.span(label, class: "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold #{classes}")
  end
end
