# rbs_inline: enabled

module SolidObjects
  class JsonCompatibility
    PROBE = '{"probe":1}'

    # @rbs @decode: ^(String) -> untyped

    # @rbs (?decode: ^(String) -> untyped) -> void
    def initialize(decode: ActiveSupport::JSON.method(:decode))
      @decode = decode
    end

    # @rbs () -> String?
    def problem
      decode.call(PROBE)
      nil
    rescue ArgumentError => error
      "Active Support #{ActiveSupport.version} cannot decode JSON with the json gem #{JSON::VERSION} " \
        "(#{error.message}). Add gem \"json\", \"~> 2\" to the Gemfile, " \
        "or use a Rails release that supports json 3"
    end

    # @rbs () -> void
    def warn_about_problem
      message = problem
      return unless message

      warn "[solid_objects] #{message}"
    end

    private

    attr_reader :decode
  end
end
