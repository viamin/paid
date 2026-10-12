# frozen_string_literal: true

mobile_api_schema = Rails.root.join("docs/api/openapi.yaml").to_s
strict_validation = Rails.env.test?

contract_error_handler = lambda do |error, env|
  Rails.logger.warn(
    message: "mobile_api.contract_validation_failed",
    error_class: error.class.name,
    error_message: error.message,
    request_method: env["REQUEST_METHOD"],
    request_path: env["PATH_INFO"]
  )
end

contract_options = {
  schema_path: mobile_api_schema,
  prefix: "/api/v1",
  strict: strict_validation,
  raise: strict_validation,
  ignore_error: !strict_validation,
  error_handler: contract_error_handler,
  strict_reference_validation: true
}.freeze

# Validate the app's uncompressed response. The compression initializer runs
# after this one and also inserts after Rack::Sendfile, placing Rack::Deflater
# before Committee in the final stack. Rack middleware unwinds responses from
# the inside out, so Committee receives JSON before it is gzip-compressed.
Rails.application.config.middleware.insert_after Rack::Sendfile, Committee::Middleware::ResponseValidation, **contract_options
Rails.application.config.middleware.insert_after Rack::Sendfile, Committee::Middleware::RequestValidation, **contract_options
