module PricingCatalog
  PERIODS = %w[Summer Autumn Winter Spring].freeze
  HOTELS  = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  ROOMS   = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  ALL_COMBINATIONS = PERIODS.product(HOTELS, ROOMS)
    .map { |period, hotel, room| { period:, hotel:, room: } }
    .freeze
end
