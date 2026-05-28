module Api::V1
  class PricingService < BaseService
    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      rate = RateCacheService.get_rate(period: @period, hotel: @hotel, room: @room)
      if rate
        @result = rate
      else
        @not_found = true
        errors << 'Rate not found'
      end
    rescue RateApiError => e
      errors << e.message
    rescue StandardError => e
      Rails.logger.error("event=pricing_unexpected_error class=#{e.class} message=#{e.message}")
      errors << 'An unexpected error occurred'
    end

    def not_found?
      @not_found || false
    end
  end
end
