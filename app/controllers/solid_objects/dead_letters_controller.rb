# rbs_inline: enabled

module SolidObjects
  class DeadLettersController < ApplicationController
    # @rbs () -> void
    def index
      @dead_letters = DeadLetter.order(last_failed_at: :desc, id: :desc).limit(250)
      respond_to do |format|
        format.html
        format.json { render json: @dead_letters }
      end
    end

    # @rbs () -> void
    def retry
      message_reference = SolidObjects.dead_letters.retry(
        params[:id].to_i,
        authorization_context: self
      )
      redirect_to dead_letters_path, notice: "Retried as message #{message_reference.id}"
    end
  end
end
