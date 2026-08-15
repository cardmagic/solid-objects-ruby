# rbs_inline: enabled

module SolidObjects
  class Web
    # Counts and slices one relation. The page size is clamped because the page
    # number and the page size both arrive from the query string, and an
    # operator page that accepts an unbounded limit is a denial of service
    # against the database the actors run on.
    class Paginator
      DEFAULT_PER_PAGE = 25
      MAXIMUM_PER_PAGE = 200

      # @rbs @page: Integer
      # @rbs @per_page: Integer
      # @rbs @total: Integer
      # @rbs @records: Array[untyped]

      attr_reader :page, :per_page, :total, :records

      # @rbs (relation: untyped, ?page: String?, ?per_page: String?) -> void
      def initialize(relation:, page: nil, per_page: nil)
        @per_page = bounded(per_page, default: DEFAULT_PER_PAGE, maximum: MAXIMUM_PER_PAGE)
        @total = relation.count
        @page = bounded(page, default: 1, maximum: last_page)
        @records = relation.offset((@page - 1) * @per_page).limit(@per_page).to_a
      end

      # @rbs () -> Integer
      def last_page
        [ (total.to_f / per_page).ceil, 1 ].max
      end

      # @rbs () -> Integer?
      def previous_page
        (page > 1) ? page - 1 : nil
      end

      # @rbs () -> Integer?
      def next_page
        (page < last_page) ? page + 1 : nil
      end

      # @rbs () -> Integer
      def first_record
        total.zero? ? 0 : ((page - 1) * per_page) + 1
      end

      # @rbs () -> Integer
      def last_record
        [ page * per_page, total ].min
      end

      private

      # @rbs (String?, default: Integer, maximum: Integer) -> Integer
      def bounded(value, default:, maximum:)
        requested = Integer(value.to_s, 10, exception: false)
        return default unless requested&.positive?

        [ requested, maximum ].min
      end
    end
  end
end
