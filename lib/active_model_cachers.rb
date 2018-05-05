require 'active_model_cachers/version'
require 'active_model_cachers/config'
require 'active_model_cachers/cache_service_factory'
require 'active_model_cachers/cacher'
require 'active_model_cachers/hook_dependencies'
require 'active_model_cachers/hook_on_model_delete'
require 'active_record'
require 'active_record/relation'

module ActiveModelCachers
  def self.config
    @config ||= Config.new
    yield(@config) if block_given?
    return @config
  end
end

module ActiveModelCachers::ActiveRecord
  def cache_self
    cache_at(nil, nil, expire_by: self.to_s)
  end

  def cache_at(column, query = nil, expire_by: nil, on: nil)
    service_klass, with_id = ActiveModelCachers::CacheServiceFactory.create_for_active_model(self, column, &query)
    
    expire_by ||= ->{
      reflect = reflect_on_association(column)
      next reflect ? reflect.class_name : "#{self}##{column}"
    }[]

    define_callback_for_cleaning_cache(expire_by, on: on){|id| service_klass.clean_at(with_id ? id : nil) }
  end

  if Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new('4')
    # define #find_by for Rails 3
    def find_by(*args)
      where(*args).order('').first
    end

    # after_commit in Rails 3 cannot specify multiple :on
    # EX: 
    #   after_commit ->{ ... }, on: [:create, :destroy]
    #
    # Should rewrite it as:
    #   after_commit ->{ ... }, on: :create
    #   after_commit ->{ ... }, on: :destroy

    def after_commit(*args, &block) # mass-assign protected attributes `id` In Rails 3
      if args.last.is_a?(Hash)
        if (on = args.last[:on]).is_a?(Array)
          return on.each{|s| after_commit(*[*args[0...-1], { **args[-1], on: s }], &block) }
        end
      end
      super
    end
  end

  private

  def define_callback_for_cleaning_cache(expire_by, on: nil, &clean)
    class_name, column = expire_by.split('#', 2)
    define_callback_proc = proc do
      on_delete{|id| clean.call(id) }
      if column == nil
        after_commit ->{ clean.call(id) if previous_changes.present? || destroyed? }, on: on
      else
        after_commit ->{ clean.call(id) if previous_changes.key?(column) || destroyed? }, on: on
      end
    end
    ActiveSupport::Dependencies.onload(class_name, &define_callback_proc)
  end
end

ActiveRecord::Base.send(:extend, ActiveModelCachers::ActiveRecord)
