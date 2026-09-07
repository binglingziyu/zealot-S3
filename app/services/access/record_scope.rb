# frozen_string_literal: true
module Access
  class RecordScope
    def self.resolve(user, scope, action: :view)
      relation = scope.respond_to?(:all) ? scope.all : scope
      apps = AppAccess.scope(user, action: action).select(:id)
      case relation.klass.name
      when 'App'
        relation.where(id: apps)
      when 'Scheme', 'DebugFile', 'StoredObject', 'UploadSession', 'Collaborator'
        relation.where(app_id: apps)
      when 'Channel'
        relation.where(scheme_id: Scheme.where(app_id: apps).select(:id))
      when 'Release'
        relation.where(channel_id: Channel.where(scheme_id: Scheme.where(app_id: apps).select(:id)).select(:id))
      when 'Metadatum'
        releases = resolve(user, Release).select(:id)
        related = relation.where(release_id: releases)
        user ? related.or(relation.where(release_id: nil, user_id: user.id)) : relation.none
      else
        raise ArgumentError, "No application scope for #{relation.klass.name}"
      end
    end
  end
end
