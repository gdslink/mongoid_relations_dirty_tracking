require 'mongoid'
require 'active_support/concern'
require 'active_support/core_ext/module/aliasing'


module Mongoid
  module RelationsDirtyTracking
    extend ActiveSupport::Concern

    included do
      after_initialize  :store_relations_shadow
      after_save        :store_relations_shadow

      cattr_accessor :relations_dirty_tracking_options
      self.relations_dirty_tracking_options = { only: [], except: ['versions'] }

    end


    def store_relations_shadow
      @relations_shadow = {}
      self.class.tracked_relations.each do |rel_name|
        @relations_shadow[rel_name] = tracked_relation_attributes(rel_name)
      end
    end


    def relation_changes
      changes = {}
      @relations_shadow.each_pair do |rel_name, shadow_values|
        current_values = tracked_relation_attributes(rel_name)
        new_changes = transform_changes_by_type(current_values)
        changes[rel_name] = new_changes if new_changes and new_changes[0] != new_changes[1]
      end
      changes
    end

    def transform_changes_by_type(o)
      case o
        when Hash
          transform_hash(o)
        when Array
          transform_array(o)
        else
          o
      end
    end

    def transform_hash(h)
      o = h.inject({}) do |hash, element|
        hash[element[0]] = element[1].is_a?(Array) ? element[1][0] : element[1]
        hash
      end
      m = h.inject({}) do |hash, element|
        hash[element[0]] = element[1][1]
        hash
      end
      return [o, m]
    end

    def transform_array(a)
      o, m = [], []
      a.each do |h|
        r = transform_hash(h)
        o << r[0]
        m << r[1]
      end
      return [o, m]
    end

    def changes_with_relations
      (changes || {}).merge relation_changes
    end

    def relations_changed?
      !relation_changes.empty?
    end


    def changed_with_relations?
      changes or relations_changed?
    end


    def tracked_relation_attributes(rel_name)
      rel_name = rel_name.to_s
      values = nil
      if meta = relations[rel_name]
        values = if meta.relation == Mongoid::Relations::Embedded::One
                   method_to_call = send(rel_name).respond_to?(:changes_with_relations) ? :changes_with_relations : :changes
                   send(rel_name) && send(rel_name).send(method_to_call).try(:clone).delete_if {|key, _| ['edited_by', 'locked'].include? key }
                 elsif meta.relation == Mongoid::Relations::Embedded::Many
                   send(rel_name) && send(rel_name).map {|child|
                     method_to_call = child.respond_to?(:changes_with_relations) ? :changes_with_relations : :changes
                     child.send(method_to_call)
                   }.delete_if {|key, _| ['edited_by', 'locked'].include? key }
                 elsif meta.relation == Mongoid::Relations::Referenced::One
                   send(rel_name) && { "#{meta.key}" => send(rel_name)[meta.key] }
                 elsif meta.relation == Mongoid::Relations::Referenced::Many
                   send("#{rel_name.singularize}_ids").map {|id| { "#{meta.key}" => id } }
                 elsif meta.relation == Mongoid::Relations::Referenced::ManyToMany
                   send("#{rel_name.singularize}_ids").map {|id| { "#{meta.primary_key}" => id } }
                 elsif meta.relation == Mongoid::Relations::Referenced::In
                   send(meta.foreign_key) && { "#{meta.foreign_key}" => send(meta.foreign_key)}
                 end
      end
      values
    end


    module ClassMethods

      def relations_dirty_tracking(options = {})
        relations_dirty_tracking_options[:only] += [options[:only] || []].flatten.map(&:to_s)
        relations_dirty_tracking_options[:except] += [options[:except] || []].flatten.map(&:to_s)
      end


      def track_relation?(rel_name)
        rel_name = rel_name.to_s
        options = relations_dirty_tracking_options
        to_track = (!options[:only].blank? && options[:only].include?(rel_name)) \
          || (options[:only].blank? && !options[:except].include?(rel_name))

        to_track && [Mongoid::Relations::Embedded::One, Mongoid::Relations::Embedded::Many,
                     Mongoid::Relations::Referenced::One, Mongoid::Relations::Referenced::Many,
                     Mongoid::Relations::Referenced::ManyToMany, Mongoid::Relations::Referenced::In].include?(relations[rel_name].try(:relation))
      end


      def tracked_relations
        @tracked_relations ||= relations.keys.select {|rel_name| track_relation?(rel_name) }
      end
    end
  end
end
