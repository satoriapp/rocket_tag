module RocketTag
  module Taggable
    def self.included(base)
      base.extend ClassMethods
    end

    class Manager

      attr_reader :contexts
      attr_writer :contexts
      attr_reader :klass

      def self.parse_tags list
        require 'csv'
        if list.kind_of? String
          # for some reason CSV parser cannot handle
          #
          #     hello, "foo"
          #
          # but must be
          #
          #     hello,"foo"
          return [] if list.empty?
          list = list.gsub /,\s+"/, ',"'
          list = list.parse_csv.map &:strip
        else
          list
        end
      end

      def initialize klass
        @klass = klass
        @contexts = Set.new
        setup_relations
      end

      def setup_relations
        klass.has_many :taggings , :dependent => :destroy , :as => :taggable, :class_name => "RocketTag::Tagging"
        klass.has_many :tags     , :source => :tag, :through => :taggings, :class_name => "RocketTag::Tag"
      end
    end

    def taggings_for_context context_val
      taggings.where('taggings.context': context_val.to_s)
    end

    def destroy_tags_for_context context
      taggings_for_context(context).delete_all
    end

    module InstanceMethods

      def reload_with_tags(options = nil)
        self.class.rocket_tag.contexts.each do |context|
          write_context context, []
        end
        @tags_cached = false
        cache_tags
        reload_without_tags(options)
      end

      def cache_tags
        unless @tags_cached
          tags_by_context ||= send("taggings").group_by{|f| f.context }
          tags_by_context.each do |context,v|
            write_context context, v.map{|t| t.tag.name unless t.tag.nil?}
          end
          @tags_cached = true
        end
      end

      def write_context context, list
        @contexts ||= {}
        @contexts[context.to_sym] = RocketTag.clean_tags(list)
      end

      def tags_for_context context
        @contexts ||= {}
        @contexts[context.to_sym] || []
      end

      # Find models with similar tags to the
      # current model ordered is decending
      # order of the number of matches
      def tagged_similar options = {}
        context = options.delete :on

        contexts = self.class.normalize_contexts context,
          self.class.rocket_tag.contexts

        q = self.class.tagged_with Hash[*contexts.map{|c|
          [c, tags_for_context(c)]
        }.flatten(1)]

        # Exclude self from the results
        q.where.not(id: self.id)
      end
    end

    module ClassMethods

      def rocket_tag
        @rocket_tag ||= RocketTag::Taggable::Manager.new(self)
      end

      def is_valid_context? context
          rocket_tag.contexts.include? context
      end

      def normalize_contexts(context, default_if_nil = [])
        contexts = if context
          if context.class == Array
            context
          else
            [context]
          end
        else
          default_if_nil
        end

        validate_contexts(contexts)

        contexts
      end

      def normalize_tags_list(tags_list)
        case tags_list.class.to_s
          when 'String'
            [tags_list]
          when 'Array'
            tags_list
          else
            raise "Provided tags: #{tags_list} are not allowed. You can pass Array or String only."
        end
      end

      # Verify contexts are valid for the taggable type
      def validate_contexts contexts
        contexts.each do |context|
          unless is_valid_context? context
            raise Exception.new("#{context} is not a valid tag context for #{self}")
          end
        end
      end

      def tagged_with tags_list, options = {}
        # Grab table name
        t = self.table_name
        q = joins(taggings: :tag)

        case tags_list
          when Hash
            # A tag can only match it's context
            tag_table = Tag.arel_table
            tagging_table = Tagging.arel_table

            # 'Array' of nodes, each node consists of 2 queries with AND condition.
            nodes = tags_list.each_key.collect{ |context| tag_table[:name].in(tags_list[context]).and(tagging_table[:context].eq(context)) }
            # Chain all noded together by OR condition
            nodes_grouped_by_or = nodes.inject(nodes.shift) { |memo, node| memo.or(Arel::Nodes::Grouping.new(node)) }

            q = q.where(nodes_grouped_by_or)
          else
            # Convert string to array if nessesary.
            tags_list = normalize_tags_list(tags_list)

            # Make sure that our context will be an array.
            contexts_array = normalize_contexts(options.delete(:on))

            # Any tag can match any context
            # Apply context (IN query) only if array has some data otherwise we'll have weird problems.
            q = q.where("tags.name": tags_list) if tags_list.any?

            # Apply context (IN query) only if array has some data otherwise we'll have weird problems.
            q = q.where("taggings.context": contexts_array) if contexts_array.any?

            q
        end

        q = q.group(q.column_names.map { |x| "#{t}.#{x}" }) if q.column_names.any?
        q = q.select("COUNT(tags.id) AS tags_count").
            select("#{t}.*").
            order("tags_count desc")

        # Isolate the aggregate uery by wrapping it as
        #
        # select * from ( ..... ) tags
        q = from("(#{q.to_sql}) #{self.table_name}")

        # Restrict by minimum tag counts if required
        min = options.delete :min
        q = q.where("tags_count >= ?", min) if min

        # Require all the tags if required
        all = options.delete :all
        q = q.where(tags_count: tags_list.length) if all

        # Return the relation
        q
      end

      # Get the tags associated with this model class
      # This can be chained such as
      #
      # User.documents.tags
      def tags(options = {})
        # Grab the current scope
        self_ids = self.select(:id)

        # Grab table name
        table_name = self.to_s

        # Make sure that our context will be an array.
        contexts_array = normalize_contexts(options.delete(:on))

        q = RocketTag::Tag.joins(:taggings).
            where('taggings.taggable_type': table_name).        # Apply taggable type
            where('taggings.taggable_id IN (?)', self_ids).     # Apply current scope
            uniq

        # Apply context (IN query) only if array has some data otherwise we'll have weird problems.
        q = q.where("taggings.context": contexts_array) if contexts_array.any?

        # Return the relation
        q
      end

      # Generates a query that returns list of popular tags
      def popular_tags options={}
        tags(options)
      end

      def setup_for_rocket_tag
        unless @setup_for_rocket_tag
          @setup_for_rocket_tag = true
          class_eval do
            default_scope do
              preload(:taggings).preload(:tags)
            end

            before_save do
              @tag_dirty ||= Set.new

              @tag_dirty.each do |context|
                # Get the current tags for this context
                list = send(context)

                # Destroy all taggings
                destroy_tags_for_context context

                # Find existing tags
                exisiting_tags = list.any? ? Tag.where('name IN (?)', list) : []
                exisiting_tag_names = exisiting_tags.map &:name

                # Find missing tags
                tags_names_to_create = list - exisiting_tag_names

                # Create missing tags
                created_tags = tags_names_to_create.map do |tag_name|
                  Tag.create :name => tag_name
                end

                # Recreate taggings
                tags_to_assign = exisiting_tags + created_tags

                tags_to_assign.each do |tag|
                  tagging = Tagging.new :tag => tag,
                    :taggable => self,
                    :context => context,
                    :tagger => nil
                  self.taggings << tagging
                end
              end
              @tag_dirty = Set.new
            end
          end
        end
      end

      def attr_taggable *contexts
        unless class_variable_defined?(:@@acts_as_rocket_tag)
          include RocketTag::Taggable::InstanceMethods
          class_variable_set(:@@acts_as_rocket_tag, true)
          alias_method_chain :reload, :tags
        end

        rocket_tag.contexts += contexts

        setup_for_rocket_tag

        contexts.each do |context|
          class_eval do

            has_many "#{context}_taggings".to_sym,
              lambda { where(:context => context) },
              :source => :taggable,
              :as => :taggable

            has_many "#{context}_tags".to_sym,
              lambda { where(["taggings.context = ?", context]) },
              :source => :tag,
              :through => :taggings

            validate context do
              if not send(context).kind_of? Enumerable
                errors.add context, :invalid
              end
            end

            # This is to compensate for a rails bug that returns
            # a string for postgres
            def tags_count
              self[:tags_count].to_i
            end

            # Return an array of RocketTag::Tags for the context
            define_method "#{context}" do
              cache_tags
              tags_for_context(context)
            end

            define_method "#{context}=" do |list|
              list = Manager.parse_tags list

              # Ensure the tags are loaded
              cache_tags
              write_context(context, list)

              (@tag_dirty ||= Set.new) << context

            end
          end
        end
      end
    end
  end
end
