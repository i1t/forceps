module Forceps
  module ActsAsCopyableModel
    extend ActiveSupport::Concern

    def copy_to_local
      without_record_timestamps do
        DeepCopier.new(forceps_options).copy(self)
      end
    end

    private

    def without_record_timestamps
      self.class.base_class.record_timestamps = false
      yield
    ensure
      self.class.base_class.record_timestamps = true
    end

    def forceps_options
      Forceps.client.options
    end

    class DeepCopier
      attr_accessor :copied_remote_objects, :options, :level

      def initialize(options)
        @copied_remote_objects = {}
        @options = options
        @level = 0
      end

      def copy(remote_object)
        cached_local_copy(remote_object) || perform_copy(remote_object)
      end

      private

      def cached_local_copy(remote_object)
        copied_remote_objects[remote_object]
      end

      def perform_copy(remote_object)
        copied_object = local_copy_with_simple_attributes(remote_object)
        copied_remote_objects[remote_object] = copied_object
        copy_associated_objects(copied_object, remote_object)
        copied_object
      end

      def local_copy_with_simple_attributes(remote_object)
        if should_reuse_local_copy?(remote_object)
          find_or_clone_local_copy_with_simple_attributes(remote_object)
        else
          create_local_copy_with_simple_attributes(remote_object)
        end
      end

      def should_reuse_local_copy?(remote_object)
        finders_for_reusing_classes.include?(remote_object.class.base_class)
      end

      def finders_for_reusing_classes
        options[:reuse] || {}
      end

      def find_or_clone_local_copy_with_simple_attributes(remote_object)
        found_local_object = finder_for_remote_object(remote_object).call(remote_object)
        if found_local_object
          copy_simple_attributes(found_local_object, remote_object)
          found_local_object
        else
          create_local_copy_with_simple_attributes(remote_object)
        end
      end

      def find_local_copy_with_simple_attributes(remote_object)
        finder_for_remote_object(remote_object).call(remote_object)
      end

      def finder_for_remote_object(remote_object)
        finder = finders_for_reusing_classes[remote_object.class.base_class]
        finder = build_attribute_finder(remote_object, finder) if finder.is_a? Symbol
        finder
      end

      def build_attribute_finder(remote_object, attribute_name)
        value = remote_object.send(attribute_name)
        lambda do |object|
          object.class.base_class.where(attribute_name => value).first
        end
      end

      def create_local_copy_with_simple_attributes(remote_object)
        # 'self.dup.becomes(Invoice)' won't work because of different  AR connections.
        # todo: prepare for rails 3 and attribute protection
        debug "#{as_trace(remote_object)} copying..."

        base_class = remote_object.class.base_class
        disable_all_callbacks_for(base_class)

        cloned_object = base_class.new
        copy_attributes(cloned_object, simple_attributes_to_copy(remote_object))
        cloned_object.save!(validate: false)
        cloned_object
      end

      # Using setters explicitly to avoid having to mess with disabling mass protection in Rails 3
      def copy_attributes(target_object, attributes_map)
        attributes_map.each do |attribute_name, attribute_value|
          target_object.send("#{attribute_name}=", attribute_value)
        end
      end

      def disable_all_callbacks_for(base_class)
        [:create, :save, :update, :validate].each { |callback| base_class.reset_callbacks callback }
      end

      def simple_attributes_to_copy(remote_object)
        remote_object.attributes.except('id')
      end

      def copy_simple_attributes(target_local_object, source_remote_object)
        debug "#{as_trace(source_remote_object)} reusing..."
        target_local_object.update_columns(simple_attributes_to_copy(source_remote_object))
      end

      def logger
        Forceps.logger
      end

      def increase_level
        @level += 1
      end

      def decrease_level
        @level -= 1
      end

      def as_trace(remote_object)
        "<#{remote_object.class.base_class.name} - #{remote_object.id}>"
      end

      def debug(message)
        left_margin = "  "*level
        logger.debug "#{left_margin}#{message}"
      end

      def copy_associated_objects(local_object, remote_object)
        increase_level

        copy_objects_associated_by_association_kind(local_object, remote_object, :has_many)
        copy_objects_associated_by_association_kind(local_object, remote_object, :has_one)
        copy_objects_associated_by_association_kind(local_object, remote_object, :belongs_to)
        copy_objects_associated_by_association_kind(local_object, remote_object, :has_and_belongs_to_many)

        decrease_level
      end

      def copy_objects_associated_by_association_kind(local_object, remote_object, association_kind)
        remote_object.class.reflect_on_all_associations(association_kind).collect(&:name).each do |association_name|
          send "copy_associated_objects_in_#{association_kind}", local_object, remote_object, association_name
        end
      end

      def copy_associated_objects_in_has_many(local_object, remote_object, association_name)
        remote_object.send(association_name).find_each do |remote_associated_object|
          local_object.send(association_name) << copy(remote_associated_object)
        end
      end

      def copy_associated_objects_in_has_one(local_object, remote_object, association_name)
        remote_associated_object = remote_object.send(association_name)
        local_object.send "#{association_name}=", remote_associated_object && copy(remote_associated_object)
        local_object.save!
      end

      def copy_associated_objects_in_belongs_to(local_object, remote_object, association_name)
        copy_associated_objects_in_has_one local_object, remote_object, association_name
      end

      def copy_associated_objects_in_has_and_belongs_to_many(local_object, remote_object, association_name)
        remote_object.send(association_name).find_each do |remote_associated_object|
          # TODO: Review dirty way to avoid copying objects related by has_and_belong_to_many in both extremes twice
          cloned_local_associated_object = copy(remote_associated_object)
          unless local_object.send(association_name).where(id: cloned_local_associated_object.id).exists?
            local_object.send(association_name) << cloned_local_associated_object
          end
        end
      end
    end
  end
end

ActiveRecord::Base.send :include, Forceps::ActsAsCopyableModel