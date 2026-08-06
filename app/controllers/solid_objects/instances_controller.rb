# rbs_inline: enabled

module SolidObjects
  class InstancesController < ApplicationController
    # @rbs () -> void
    def index
      @instances = Instance.order(updated_at: :desc, id: :desc).limit(250)
      respond_to do |format|
        format.html
        format.json { render json: @instances }
      end
    end

    # @rbs () -> void
    def show
      @instance = Instance.find(params[:id])
      @messages = @instance.messages.order(sequence: :desc).limit(250)
      respond_to do |format|
        format.html
        format.json do
          render json: {
            instance: @instance,
            messages: @messages
          }
        end
      end
    end
  end
end
