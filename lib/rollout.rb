require "rollout/version"
require "zlib"
require "set"

class Rollout
  class Feature
    attr_accessor :groups, :users, :percentage
    attr_reader :name, :options

    def initialize(name, string = nil, opts = {})
      @options = opts
      @name    = name

      if string
        raw_percentage,raw_users,raw_groups = string.split("|")
        @percentage = raw_percentage.to_i
        @users = (raw_users || "").split(",").map(&:to_s).to_set
        @groups = (raw_groups || "").split(",").map(&:to_sym).to_set
      else
        clear
      end
    end

    def serialize
      if @options[:max_users]
        "#{@percentage}|#{@users.take(@options[:max_users]).to_a.join(",")}|#{@groups.to_a.join(",")}"
      else
        "#{@percentage}|#{@users.to_a.join(",")}|#{@groups.to_a.join(",")}"
      end
    end

    def add_user(user)
      id = user_id(user)
      @users << id unless @users.include?(id)
    end

    def remove_user(user)
      @users.delete(user_id(user))
    end

    def add_group(group)
      @groups << group.to_sym unless @groups.include?(group.to_sym)
    end

    def remove_group(group)
      @groups.delete(group.to_sym)
    end

    def clear
      @groups = Set.new
      @users = Set.new
      @percentage = 0
    end

    def active?(rollout, user)
      if user
        id = user_id(user)
        user_in_percentage?(id) ||
          user_in_active_users?(id) ||
            user_in_active_group?(user, rollout)
      else
        @percentage == 100
      end
    end

    def to_hash
      {
        percentage: @percentage,
        groups: @groups,
        users: @users
      }
    end

    private
      def user_id(user)
        if user.is_a?(Fixnum) || user.is_a?(String)
          user.to_s
        else
          user.send(id_user_by).to_s
        end
      end

      def id_user_by
        @options[:id_user_by] || :id
      end

      def user_in_percentage?(user)
        Zlib.crc32(user_id_for_percentage(user)) % 100 < @percentage
      end

      def user_id_for_percentage(user)
        if @options[:randomize_percentage]
          user_id(user).to_s + @name.to_s
        else
          user_id(user)
        end
      end

      def user_in_active_users?(user)
        @users.include?(user_id(user))
      end

      def user_in_active_group?(user, rollout)
        @groups.any? do |g|
          rollout.active_in_group?(g, user)
        end
      end
  end

  def initialize(storage, opts = {})
    @storage = storage
    @options = opts
    @groups  = { all: lambda { |user| true } }
  end

  def activate(feature)
    with_feature(feature) do |f|
      f.percentage = 100
    end
  end

  def deactivate(feature)
    with_feature(feature) do |f|
      f.clear
    end
  end

  def delete(feature)
    features = (@storage.get(features_key) || "").split(",").map(&:to_sym)
    features.delete(feature)
    @storage.set(features_key, features.join(","))
    @storage.del(key(feature))
  end

  def set(feature, desired_state)
    with_feature(feature) do |f|
      if desired_state
        f.percentage = 100
      else
        f.clear
      end
    end
  end

  def activate_group(feature, group)
    with_feature(feature) do |f|
      f.add_group(group)
    end
  end

  def deactivate_group(feature, group)
    with_feature(feature) do |f|
      f.remove_group(group)
    end
  end

  def activate_user(feature, user)
    with_feature(feature) do |f|
      f.add_user(user)
    end
  end

  def deactivate_user(feature, user)
    with_feature(feature) do |f|
      f.remove_user(user)
    end
  end

  def activate_users(feature, users)
    with_feature(feature) do |f|
      users.each{|user| f.add_user(user)}
    end
  end

  def deactivate_users(feature, users)
    with_feature(feature) do |f|
      users.each{|user| f.remove_user(user)}
    end
  end

  def define_group(group, &block)
    @groups[group.to_sym] = block
  end

  def active?(feature, user = nil)
    feature = get(feature)
    feature.active?(self, user)
  end

  def inactive?(feature, user = nil)
    !active?(feature, user)
  end

  def activate_percentage(feature, percentage)
    with_feature(feature) do |f|
      f.percentage = percentage
    end
  end

  def deactivate_percentage(feature)
    with_feature(feature) do |f|
      f.percentage = 0
    end
  end

  def active_in_group?(group, user)
    f = @groups[group.to_sym]
    f && f.call(user)
  end

  def get(feature)
    string = @storage.get(key(feature))
    Feature.new(feature, string, @options)
  end

  def features
    (@storage.get(features_key) || "").split(",").map(&:to_sym)
  end

  def feature_states(user = nil)
    features.each_with_object({}) do |f, hash|
      hash[f] = active?(f, user)
    end
  end

  def active_features(user = nil)
    features.select do |f|
      active?(f, user)
    end
  end

  def clear!
    features.each do |feature|
      with_feature(feature) { |f| f.clear }
      @storage.del(key(feature))
    end

    @storage.del(features_key)
  end

  private

  def key(name)
    "feature:#{name}"
  end

  def features_key
    "feature:__features__"
  end

  def with_feature(feature)
    f = get(feature)
    yield(f)
    save(f)
  end

  def save(feature)
    @storage.set(key(feature.name), feature.serialize)
    @storage.set(features_key, (features | [feature.name.to_sym]).join(","))
  end
end
