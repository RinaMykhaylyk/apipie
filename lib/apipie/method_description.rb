module Apipie
  class MethodDescription
    attr_reader :full_description, :method, :resource, :apis, :examples, :see, :formats, :headers, :show
    attr_accessor :metadata

    def initialize(method, resource, dsl_data)
      @method = method.to_s
      @resource = resource
      @from_concern = dsl_data[:from_concern]
      @apis = ApisService.new(resource, method, dsl_data).call

      @full_description = dsl_data[:description] || ''

      @errors = dsl_data[:errors].map do |args|
        Apipie::ErrorDescription.from_dsl_data(args)
      end

      @success = dsl_data[:success].map do |args|
        Apipie::SuccessDescription.from_dsl_data(args)
      end

      @tag_list = dsl_data[:tag_list]

      @returns = dsl_data[:returns].map do |code,args|
        Apipie::ResponseDescription.from_dsl_data(self, code, args)
      end

      @see = dsl_data[:see].map do |args|
        Apipie::SeeDescription.new(args)
      end

      @formats = dsl_data[:formats]
      @examples = dsl_data[:examples]
      @examples += load_recorded_examples

      @metadata = dsl_data[:meta]

      @params_ordered = dsl_data[:params].map do |args|
        Apipie::ParamDescription.from_dsl_data(self, args)
      end.reject(&:response_only?)

      @params_ordered = ParamDescription.unify(@params_ordered)
      @headers = dsl_data[:headers]

      @show = if dsl_data.key? :show
        dsl_data[:show]
      else
        true
      end
    end

    def id
      "#{resource._id}##{method}"
    end

    def params
      params_ordered.reduce(ActiveSupport::OrderedHash.new) { |h,p| h[p.name] = p; h }
    end

    def params_ordered_self
      @params_ordered
    end

    def params_ordered
      all_params = []
      parent = Apipie.get_resource_description(@resource.controller.superclass)

      # get params from parent resource description
      [parent, @resource].compact.each do |resource|
        resource_params = resource._params_args.map do |args|
          Apipie::ParamDescription.from_dsl_data(self, args)
        end
        merge_params(all_params, resource_params)
      end

      merge_params(all_params, @params_ordered)
      all_params.find_all(&:validator)
    end

    def returns_self
      @returns
    end

    def tag_list
      all_tag_list = []
      parent = Apipie.get_resource_description(@resource.controller.superclass)

      # get tags from parent resource description
      parent_tags = [parent, @resource].compact.flat_map(&:_tag_list_arg)
      Apipie::TagListDescription.new((parent_tags + @tag_list).uniq.compact)
    end

    def returns
      all_returns = []
      parent = Apipie.get_resource_description(@resource.controller.superclass)

      # get response descriptions from parent resource description
      [parent, @resource].compact.each do |resource|
        resource_returns = resource._returns_args.map do |code, args|
          Apipie::ResponseDescription.from_dsl_data(self, code, args)
        end
        merge_returns(all_returns, resource_returns)
      end

      merge_returns(all_returns, @returns)
    end

    def errors
      return @merged_errors if @merged_errors
      @merged_errors = []
      if @resource
        resource_errors = @resource._errors_args.map do |args|
          Apipie::ErrorDescription.from_dsl_data(args)
        end

        # exclude overwritten parent errors
        @merged_errors = resource_errors.find_all do |err|
          !@errors.any? { |e| e.code == err.code }
        end
      end
      @merged_errors.concat(@errors)
      return @merged_errors
    end

    def success
      return @merged_success if @merged_success
      @merged_success = []
      if @resource
        resource_success = @resource._success_args.map do |args|
          Apipie::SuccessDescription.from_dsl_data(args)
        end

        @merged_success = resource_success.find_all do |succ|
          !@success.any? { |e| e.code == succ.code }
        end
      end
      @merged_success.concat(@success)
      return @merged_success
    end

    def version
      resource._version
    end

    def doc_url
      crumbs = []
      crumbs << @resource._version if Apipie.configuration.version_in_url
      crumbs << @resource._id
      crumbs << @method
      Apipie.full_url crumbs.join('/')
    end

    def create_api_url(api)
      path = api.path
      unless api.from_routes
        path = "#{@resource._api_base_url}#{path}"
      end
      path = path[0..-2] if path[-1..-1] == '/'
      return path
    end

    def method_apis_to_json(lang = nil)
      @apis.each.collect do |api|
        {
          :api_url => create_api_url(api),
          :http_method => api.http_method.to_s,
          :short_description => Apipie.app.translate(api.short_description, lang),
          :deprecated => resource._deprecated || api.options[:deprecated]
        }
      end
    end

    def see
      @see
    end

    def formats
      @formats || @resource._formats
    end

    def to_json(lang = nil)
      {
        :doc_url => doc_url,
        :name => @method,
        :apis => method_apis_to_json(lang),
        :formats => formats,
        :full_description => Apipie.markup_to_html(Apipie.app.translate(@full_description, lang)),
        :errors => errors.map{ |error| error.to_json(lang) }.flatten,
        :success => success.map{ |succ| succ.to_json(lang) }.flatten,
        :params => params_ordered.map{ |param| param.to_json(lang) }.flatten,
        :returns => @returns.map{ |return_item| return_item.to_json(lang) }.flatten,
        :examples => @examples,
        :metadata => @metadata,
        :see => see.map(&:to_json),
        :headers => headers,
        :show => @show
      }
    end

    # was the description defines in a module instead of directly in controller?
    def from_concern?
      @from_concern
    end

    def method_name
      @method
    end

    private

    def merge_params(params, new_params)
      new_param_names = Set.new(new_params.map(&:name))
      params.delete_if { |p| new_param_names.include?(p.name) }
      params.concat(new_params)
    end

    def merge_returns(returns, new_returns)
      new_return_codes = Set.new(new_returns.map(&:code))
      returns.delete_if { |p| new_return_codes.include?(p.code) }
      returns.concat(new_returns)
    end

    def load_recorded_examples
      (Apipie.recorded_examples[id] || []).
        find_all { |ex| ex["show_in_doc"].to_i > 0 }.
        find_all { |ex| ex["versions"].nil? || ex["versions"].include?(self.version) }.
        sort_by { |ex| ex["show_in_doc"] }.
        map { |ex| format_example(ex.symbolize_keys) }
    end

    def format_example_data(data)
      case data
      when Array, Hash
        JSON.pretty_generate(data).gsub(/: \[\s*\]/,": []").gsub(/\{\s*\}/,"{}")
      else
        data
      end
    end

    def format_example(ex)
      example = ""
      example << "// #{ex[:title]}\n" if ex[:title].present?
      example << "#{ex[:verb]} #{ex[:path]}"
      example << "?#{ex[:query]}" unless ex[:query].blank?
      example << "\n" << format_example_data(ex[:request_data]).to_s if ex[:request_data]
      example << "\n" << ex[:code].to_s
      example << "\n" << format_example_data(ex[:response_data]).to_s if ex[:response_data]
      example
    end
  end
end
