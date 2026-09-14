# rbs_inline: enabled

target :lib do
  signature "sig/generated"
  signature "sig/support"
  signature "sig/public"
  check "lib"

  configure_code_diagnostics(Diagnostic::Ruby.lenient)

  ignore "lib/solid_objects/engine.rb"
  ignore "lib/solid_objects/effect_payload.rb"
end

target :effect_payloads do
  signature "sig/generated"
  signature "sig/support"
  signature "sig/public"
  check "lib/solid_objects/effect_payload.rb"

  configure_code_diagnostics(Diagnostic::Ruby.strict)
end
