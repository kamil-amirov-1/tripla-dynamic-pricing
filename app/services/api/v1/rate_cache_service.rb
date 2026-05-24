module Api::V1
  class RateCacheService
    CACHE_TTL = 5.minutes

    def self.get_rate(period:, hotel:, room:)
      cached = Rails.cache.read(cache_key(period, hotel, room))
      return cached if cached

      rates = fetch_and_cache_all
      rates.find { |r| matches?(r, period:, hotel:, room:) }
           &.fetch('rate', nil)
    end

    private_class_method def self.fetch_and_cache_all
      response = RateApiClient.get_rates_batch(PricingCatalog::ALL_COMBINATIONS)

      unless response.success?
        message = response.parsed_response&.dig('error') || 'Pricing model returned an error'
        raise RateApiError, message
      end

      rates = response.parsed_response&.dig('rates')
      raise RateApiError, 'Invalid response structure from pricing model' unless rates.is_a?(Array)

      rates.each do |r|
        next unless r['period'] && r['hotel'] && r['room'] && r['rate']
        Rails.cache.write(cache_key(r['period'], r['hotel'], r['room']), r['rate'], expires_in: CACHE_TTL)
      end

      missing_count = PricingCatalog::ALL_COMBINATIONS.count { |c| rates.none? { |r| matches?(r, **c) } }
      Rails.logger.warn("Pricing model missing #{missing_count} combination(s)") if missing_count > 0

      rates
    end

    private_class_method def self.matches?(rate, period:, hotel:, room:)
      rate['period'] == period && rate['hotel'] == hotel && rate['room'] == room
    end

    private_class_method def self.cache_key(period, hotel, room)
      "pricing:rate:#{period}:#{hotel}:#{room}"
    end
  end
end
