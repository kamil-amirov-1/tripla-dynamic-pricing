class Api::V1::PricingController < ApplicationController
  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]

    service = Api::V1::PricingService.new(period:, hotel:, room:)
    service.run
    if service.valid?
      render json: { rate: service.result }
    elsif service.not_found?
      render json: { error: service.errors.join(', ') }, status: :not_found
    else
      render json: { error: service.errors.join(', ') }, status: :service_unavailable
    end
  end

  private

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless PricingCatalog::PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{PricingCatalog::PERIODS.join(', ')}" }, status: :bad_request
    end

    unless PricingCatalog::HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{PricingCatalog::HOTELS.join(', ')}" }, status: :bad_request
    end

    unless PricingCatalog::ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{PricingCatalog::ROOMS.join(', ')}" }, status: :bad_request
    end
  end
end
