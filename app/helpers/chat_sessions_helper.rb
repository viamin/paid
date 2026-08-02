# frozen_string_literal: true

module ChatSessionsHelper
  CHAT_SESSION_STATUS_STYLES = {
    "active" => "bg-green-100 text-green-700",
    "idle" => "bg-yellow-100 text-yellow-800",
    "closed" => "bg-gray-100 text-gray-600",
    "archived" => "bg-gray-100 text-gray-600"
  }.freeze

  CHAT_MODE_STYLES = {
    "inline" => "bg-blue-100 text-blue-700",
    "container" => "bg-indigo-100 text-indigo-700"
  }.freeze

  CHAT_CONTAINER_CAPABILITY_STYLES = {
    "none" => "bg-gray-100 text-gray-600",
    "pending" => "bg-amber-100 text-amber-800",
    "provisioning" => "bg-amber-100 text-amber-800",
    "ready" => "bg-green-100 text-green-700",
    "failed" => "bg-rose-100 text-rose-700",
    "stopped" => "bg-gray-100 text-gray-600"
  }.freeze

  def chat_session_status_badge(chat_session)
    badge_label(chat_session.status.titleize, CHAT_SESSION_STATUS_STYLES.fetch(chat_session.status, CHAT_SESSION_STATUS_STYLES["archived"]))
  end

  def chat_mode_badge(chat_session)
    mode = chat_session.inline_only? ? "inline" : "container"
    label = chat_session.inline_only? ? "Inline" : "Container"

    badge_label(label, CHAT_MODE_STYLES.fetch(mode))
  end

  def chat_container_status_badge(chat_session)
    capability = chat_session.container_capability
    classes = CHAT_CONTAINER_CAPABILITY_STYLES.fetch(capability, CHAT_CONTAINER_CAPABILITY_STYLES["none"])
    tag.span(capability.to_s.titleize, class: "inline-flex items-center rounded-full px-2 py-1 text-xs font-medium #{classes}",
      data: { chat_target: "capabilityBadge", capability: capability })
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
      "ml-auto max-w-2xl rounded-2xl rounded-br-md bg-gray-950 px-5 py-3.5 text-sm text-white shadow-sm"
    when "assistant"
      "max-w-3xl px-0 py-1 text-[15px] text-gray-900"
    when "tool"
      "max-w-3xl px-0 py-1 text-sm text-gray-700"
    else
      "mx-auto max-w-2xl rounded-md bg-white px-4 py-2 text-center text-xs font-medium text-gray-500 ring-1 ring-gray-200"
    end
  end

  def chat_message_wrapper_classes(message)
    return "flex justify-end" if message.role == "user"
    return "flex justify-center" if message.role == "system"

    "flex justify-start"
  end

  def chat_message_meta_classes(message)
    return "mb-2 flex items-center justify-end gap-2" if message.role == "user"

    "mb-3 flex items-center gap-2"
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
    CHAT_TOOL_STATUS_BADGES.fetch(message.tool_status, "bg-gray-100 text-gray-600")
  end

  def chat_tool_payload_excerpt(message)
    payload = chat_tool_payload(message.role == "tool" ? (message.tool_result || message.content) : message.tool_arguments)
    if (plan = chat_configuration_profile_plan(payload))
      return configuration_profile_plan_summary(plan)
    end

    chat_tool_payload_summary(payload)
  end

  def chat_tool_summary(message)
    summary = chat_tool_payload_excerpt(message)
    [ message.tool_name.presence || "Unknown tool", chat_tool_status_label(message), summary ].compact.join(" · ")
  end

  def chat_tool_expanded_by_default?(message)
    message.pending_confirmation?
  end

  def chat_configuration_profile_plan(payload)
    hash = chat_tool_payload(payload)
    return unless hash.is_a?(Hash)

    plan = chat_tool_payload_value(hash, "plan") || hash
    return unless configuration_profile_plan_payload?(plan)

    plan.deep_symbolize_keys
  end

  def chat_configuration_profile_plan_changes(payload)
    plan = chat_configuration_profile_plan(payload)
    return [] unless plan

    Array(plan[:changes])
  end

  def configuration_profile_plan_summary(plan)
    change_count = Array(plan[:changes]).size
    "#{change_count} #{'change'.pluralize(change_count)}"
  end

  def configuration_profile_field_label(field)
    return "" if field.blank?

    Configuration::Profiles::Settings.fetch(field).label
  rescue ArgumentError
    field.to_s.humanize
  end

  def chat_configuration_profile_plan_title(payload)
    plan = chat_configuration_profile_plan(payload)
    return unless plan

    profile_name = plan[:profile_name].presence || plan[:profile_id].to_s.humanize
    project_id = plan[:project_id]
    [ profile_name, ("project ##{project_id}" if project_id.present?) ].compact.join(" for ")
  end

  def format_configuration_profile_change_value(value)
    case value
    when String
      value
    when NilClass
      "nil"
    else
      JSON.generate(value)
    end
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

    context = context.merge(
      "project_id" => project.id,
      "project_name" => project.name,
      "project_full_name" => project.full_name
    )

    issue = current_chat_popup_issue
    return context unless issue

    context.merge("issue_id" => issue.id)
  end

  def current_chat_popup_project
    return @project if defined?(@project) && @project.is_a?(Project)

    nil
  end

  def current_chat_popup_issue
    return @issue if defined?(@issue) && @issue.is_a?(Issue)

    nil
  end

  private

  def preview_cache
    @preview_cache ||= {}
  end

  def badge_label(label, classes)
    tag.span(label, class: "inline-flex items-center rounded-full px-2 py-1 text-xs font-medium #{classes}")
  end

  def chat_tool_payload_summary(payload)
    case payload
    when Array
      "#{payload.size} #{'item'.pluralize(payload.size)}"
    when Hash
      chat_tool_hash_payload_summary(payload)
    when String
      payload.squish.truncate(72)
    end
  end

  def chat_tool_hash_payload_summary(payload)
    return chat_tool_error_summary(payload) if chat_tool_payload_value(payload, "error").present?

    count = chat_tool_payload_value(payload, "total_count")
    return "#{count} #{'match'.pluralize(count.to_i)}" if count

    collection_key = %w[matches projects results items].find { |key| chat_tool_payload_value(payload, key).is_a?(Array) }
    return "#{chat_tool_payload_value(payload, collection_key).size} #{collection_key.humanize(capitalize: false)}" if collection_key

    path = chat_tool_payload_value(payload, "path")
    size = chat_tool_payload_value(payload, "size")
    return [ path, number_to_human_size(size) ].compact.join(" · ") if path || size

    "#{payload.size} #{'field'.pluralize(payload.size)}"
  end

  def configuration_profile_plan_payload?(payload)
    payload.is_a?(Hash) &&
      chat_tool_payload_value(payload, "profile_id").present? &&
      chat_tool_payload_value(payload, "changes").is_a?(Array)
  end

  def chat_tool_error_summary(payload)
    message = chat_tool_payload_value(payload, "message") || chat_tool_payload_value(payload, "error")
    "error: #{message.to_s.squish.truncate(64)}"
  end

  def chat_tool_payload_value(payload, key)
    payload[key] || payload[key.to_sym]
  end
end
