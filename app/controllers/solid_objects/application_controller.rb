# rbs_inline: enabled

module SolidObjects
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
    before_action :authorize_administration!

    private

    # @rbs () -> void
    def authorize_administration!
      authorized = SolidObjects.configuration.authorize_administration.call(
        action: action_name,
        resource: controller_name,
        resource_id: params[:id],
        authorization_context: self
      )
      return if authorized

      raise Unauthorized, "actor administration is not authorized"
    end
  end
end
