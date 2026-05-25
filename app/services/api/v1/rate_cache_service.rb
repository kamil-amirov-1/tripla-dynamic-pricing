module Api::V1
  class RateCacheService
    CACHE_TTL = 5.minutes
    LOCK_KEY  = 'pricing:refresh_lock'
    LOCK_TTL  = ENV.fetch('RATE_API_READ_TIMEOUT', 10).to_i + 5  # seconds; exceeds API timeout so Redis expires locks
    LOCK_WAIT = 0.05  # seconds between polls while waiting for another process to refresh
    MISSING   = '__missing__'

    RELEASE_SCRIPT = <<~LUA.freeze
      if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
      else
        return 0
      end
    LUA

    def self.get_rate(period:, hotel:, room:)
      cached = read_cache(cache_key(period, hotel, room))
      if cached == MISSING
        Rails.logger.info("event=pricing_cache_hit result=missing period=#{period} hotel=#{hotel} room=#{room}")
        return nil
      end
      if cached
        Rails.logger.info("event=pricing_cache_hit result=found period=#{period} hotel=#{hotel} room=#{room}")
        return cached
      end

      Rails.logger.info("event=pricing_cache_miss period=#{period} hotel=#{hotel} room=#{room}")
      ensure_cache_populated(period:, hotel:, room:)
      cached = read_cache(cache_key(period, hotel, room))
      cached == MISSING ? nil : cached
    end

    def self.warm_cache
      token = SecureRandom.hex
      return unless acquire_lock(token)
      Rails.logger.info("event=cache_warmer_started")
      begin
        fetch_from_api_and_cache
      ensure
        release_lock(token)
      end
    end

    private_class_method def self.ensure_cache_populated(period:, hotel:, room:)
      token = SecureRandom.hex
      if acquire_lock(token)
        Rails.logger.info("event=pricing_lock_acquired")
        begin
          fetch_from_api_and_cache
        ensure
          release_lock(token)
        end
      else
        Rails.logger.info("event=pricing_lock_waiting")
        wait_for_lock_release
        # Lock holder failed without writing - raise instead of silent nil -> 404
        raise RateApiError, 'Rate temporarily unavailable, please retry' if read_cache(cache_key(period, hotel, room)).nil?
      end
    end

    private_class_method def self.fetch_from_api_and_cache
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = RateApiClient.get_rates_batch(PricingCatalog::ALL_COMBINATIONS)

      unless response.success?
        message = response.parsed_response&.dig('error') || 'Pricing model returned an error'
        Rails.logger.error("event=pricing_upstream_error message=#{message}")
        raise RateApiError, message
      end

      rates = response.parsed_response&.dig('rates')
      raise RateApiError, 'Invalid response structure from pricing model' unless rates.is_a?(Array)

      rates.each do |r|
        next unless cacheable_rate?(r)
        write_cache(cache_key(r['period'], r['hotel'], r['room']), r['rate'], expires_in: CACHE_TTL)
      end

      missing_count = 0
      PricingCatalog::ALL_COMBINATIONS.each do |c|
        next if rates.any? { |r| cacheable_rate?(r) && matches?(r, **c) }
        write_cache(cache_key(c[:period], c[:hotel], c[:room]), MISSING, expires_in: CACHE_TTL)
        missing_count += 1
      end

      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      Rails.logger.info("event=pricing_upstream_success fetched=#{rates.size} missing=#{missing_count} duration_ms=#{duration_ms}")
      Rails.logger.warn("event=pricing_upstream_partial missing=#{missing_count}") if missing_count > 0
    end

    private_class_method def self.read_cache(key)
      Rails.cache.read(key)
    rescue => e
      Rails.logger.error("event=pricing_cache_error operation=read message=#{e.class}:#{e.message}")
      raise RateApiError, 'Pricing cache unavailable'
    end

    private_class_method def self.write_cache(key, value, expires_in:)
      result = Rails.cache.write(key, value, expires_in: expires_in)
      unless result
        Rails.logger.error("event=pricing_cache_error operation=write key=#{key}")
        raise RateApiError, 'Pricing cache unavailable'
      end
      result
    end

    private_class_method def self.acquire_lock(token)
      redis.set(LOCK_KEY, token, nx: true, ex: LOCK_TTL)
    end

    private_class_method def self.release_lock(token)
      redis.eval(RELEASE_SCRIPT, keys: [LOCK_KEY], argv: [token])
    end

    private_class_method def self.wait_for_lock_release
      deadline = LOCK_TTL.seconds.from_now
      loop do
        sleep LOCK_WAIT
        return unless redis.exists?(LOCK_KEY)
        raise RateApiError, 'Rate refresh timed out, please retry' if Time.current >= deadline
      end
    end

    private_class_method def self.redis
      @redis ||= Redis.new(
        url:                ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
        connect_timeout:    ENV.fetch('REDIS_CONNECT_TIMEOUT', 1).to_f,
        read_timeout:       ENV.fetch('REDIS_READ_TIMEOUT', 1).to_f,
        write_timeout:      ENV.fetch('REDIS_WRITE_TIMEOUT', 1).to_f,
        reconnect_attempts: ENV.fetch('REDIS_RECONNECT_ATTEMPTS', 3).to_i,
        reconnect_delay:    0.5
      )
    end

    private_class_method def self.cacheable_rate?(r)
      r['period'].present? && r['hotel'].present? && r['room'].present? && r['rate'].present? &&
        PricingCatalog::ALL_COMBINATIONS.any? { |c| matches?(r, **c) }
    end

    private_class_method def self.matches?(rate, period:, hotel:, room:)
      rate['period'] == period && rate['hotel'] == hotel && rate['room'] == room
    end

    private_class_method def self.cache_key(period, hotel, room)
      "pricing:rate:#{period}:#{hotel}:#{room}"
    end
  end
end
