class RateApiClient
  include HTTParty
  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers "Content-Type" => "application/json"
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')
  open_timeout ENV.fetch('RATE_API_CONNECT_TIMEOUT', 3).to_i
  read_timeout ENV.fetch('RATE_API_READ_TIMEOUT', 10).to_i

  def self.get_rate(period:, hotel:, room:)
    get_rates_batch([{ period:, hotel:, room: }])
  end

  def self.get_rates_batch(combinations)
    body = { attributes: combinations }.to_json
    post("/pricing", body: body)
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise RateApiError, 'Pricing model request timed out'
  rescue Errno::ECONNREFUSED, SocketError
    raise RateApiError, 'Unable to connect to pricing model'
  rescue JSON::ParserError
    raise RateApiError, 'Invalid response format from pricing model'
  rescue HTTParty::Error => e
    raise RateApiError, "Pricing model error: #{e.message}"
  end
end
