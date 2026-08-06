# rbs_inline: enabled

target :lib do
  signature "sig/generated"
  signature "sig/support"
  check "lib"

  configure_code_diagnostics(Diagnostic::Ruby.lenient)

  ignore "lib/solid_objects/engine.rb"
end
