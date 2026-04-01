# frozen_string_literal: true

module IntegrationsHelper
  def render_integration_status(record)
    if record.respond_to?(:revoked?) && record.revoked?
      status_badge("Revoked", "bg-gray-100", "text-gray-700")
    elsif record.respond_to?(:expired?) && record.expired?
      status_badge("Expired", "bg-orange-100", "text-orange-700")
    elsif record.respond_to?(:validation_failed?) && record.validation_failed?
      status_badge("Validation Failed", "bg-red-100", "text-red-700")
    elsif record.respond_to?(:validating?) && record.validating?
      status_badge("Validating...", "bg-yellow-100", "text-yellow-800")
    elsif record.respond_to?(:validation_pending?) && record.validation_pending?
      status_badge("Pending Validation", "bg-yellow-100", "text-yellow-800")
    else
      status_badge("Active", "bg-green-100", "text-green-700")
    end
  end

  def integration_show_path(record, section_key)
    case section_key
    when :repository then github_token_path(record)
    when :issue_tracking then linear_token_path(record)
    when :llm_provider then provider_api_key_path(record)
    else raise ArgumentError, "Unknown integration section: #{section_key.inspect}"
    end
  end

  private

  def status_badge(label, bg_class, text_class)
    tag.span(label, class: "inline-flex items-center rounded-md #{bg_class} px-2 py-1 text-xs font-medium #{text_class}")
  end
end
