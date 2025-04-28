module Apipie

  class ErrorDescription
    attr_reader :code, :description, :metadata, :sample

    def self.from_dsl_data(args)
      code_or_options, desc, options = args
      Apipie::ErrorDescription.new(code_or_options, desc, options)
    end

    def initialize(code_or_options, desc = nil, options = {})
      if code_or_options.is_a? Hash
        code_or_options.symbolize_keys!
        @code = code_or_options[:code]
        @metadata = code_or_options[:meta]
        @description = code_or_options[:desc] || code_or_options[:description]
        @sample = code_or_options[:sample]
      else
        @code =
          if code_or_options.is_a? Symbol
            begin
              Rack::Utils.status_code(code_or_options)
            rescue ArgumentError
              'ApipieError: Bad use of error method.'
            end
          else
            code_or_options
          end

        raise UnknownCode, code_or_options unless @code

        @metadata = options[:meta]
        @description = desc
        @sample = code_or_options[:sample]
      end
    end

    def to_json(lang)
      {
        :code => code,
        :description => Apipie.app.translate(description, lang),
        :metadata => metadata,
        :sample => sample
      }
    end

  end

end
