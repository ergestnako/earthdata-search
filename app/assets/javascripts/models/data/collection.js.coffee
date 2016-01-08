#= require models/data/granules
#= require models/data/service_options

ns = @edsc.models.data

ns.Collection = do (ko
                 DetailsModel = @edsc.models.DetailsModel
                 scalerUrl = @edsc.config.browseScalerUrl
                 thumbnailWidth = @edsc.config.thumbnailWidth
                 Granules=ns.Granules
                 GranuleQuery = ns.query.GranuleQuery
                 ServiceOptionsModel = ns.ServiceOptions
                 toParam=jQuery.param
                 extend=jQuery.extend
                 ajax = @edsc.util.xhr.ajax
                 dateUtil = @edsc.util.date
                 config = @edsc.config
                 ) ->

  openSearchKeyToEndpoint =
    cwic: (collection) ->


  collections = ko.observableArray()

  randomKey = Math.random()

  register = (collection) ->
    collection.reference()
    collections.push(collection)
    collection

  class Collection extends DetailsModel
    @awaitDatasources: (collections, callback) ->
      calls = collections.length
      aggregation = ->
        calls--
        callback(collections) if calls == 0

      for collection in collections
        collection.granuleDatasourceAsync(aggregation)


    @findOrCreate: (jsonData, query) ->
      id = jsonData.id
      featured = jsonData.featured
      for collection in collections()
        if collection.id == id
          if (jsonData.short_name? && !collection.hasAtomData()) || collection.featured != featured || jsonData.granule_count != collection.granule_count
            collection.fromJson(jsonData)
          return collection.reference()
      register(new Collection(jsonData, query, randomKey))

    @visible: ko.computed
      read: -> collection for collection in collections() when collection.visible()

    constructor: (jsonData, @query, inKey) ->
      throw "Collections should not be constructed directly" unless inKey == randomKey
      @granuleCount = ko.observable(0)

      @hasAtomData = ko.observable(false)

      @details = @asyncComputed({}, 100, @_computeCollectionDetails, this)
      @detailsLoaded = ko.observable(false)

      @spatial = @computed(@_computeSpatial, this, deferEvaluation: true)
      @timeRange = @computed(@_computeTimeRange, this, deferEvaluation: true)
      @granuleDescription = @computed(@_computeGranuleDescription, this, deferEvaluation: true)
      @granuleDatasource = ko.observable(null)
      @_renderers = []
      @_pendingRenderActions = []
      @osddUrl = @computed(@_computeOsddUrl, this, deferEvaluation: true)
      @cwic = ko.observable(@_isCwic(jsonData))
      @tags = ko.observable(jsonData.tags)

      @visible = ko.observable(false)
      @disposable(@visible.subscribe(@_visibilityChange))

      @fromJson(jsonData)

      if @granuleDatasourceName() && @granuleDatasourceName() != 'cmr'
        @has_granules = @canFocus()

      @spatial_constraint = @computed =>
        if @points?
          'point:' + @points[0].split(/\s+/).reverse().join(',')
        else
          null

      @echoGranulesUrl = @computed
        read: =>
          if @granuleDatasourceName() == 'cmr' && @granuleDatasource()
            _cloneQueryParams = (obj) ->
              return obj  if obj is null or typeof (obj) isnt "object"
              temp = new obj.constructor()
              for key of obj
                temp[key] = _cloneQueryParams(obj[key])
              temp

            queryParams = _cloneQueryParams(@granuleDatasource().toQueryParams())
            delete queryParams['datasource'] if queryParams['datasource']
            paramStr = toParam(queryParams)
            "#{@details().granule_url}?#{paramStr}"
        deferEvaluation: true

    _computeTimeRange: ->
      if @hasAtomData()
        result = dateUtil.timeSpanToIsoDate(@time_start, @time_end)
      (result || "Unknown")

    _computeSpatial: ->
      (@_spatialString("Bounding Rectangles", @boxes) ?
       @_spatialString("Points", @points) ?
       @_spatialString("Polygons", @polygons) ?
       @_spatialString("Lines", @lines))

    _spatialString: (title, spatial) ->
      if spatial
        suffix = if spatial.length > 1 then " ..." else ""
        "#{title}: #{spatial[0]}#{suffix}"
      else
        null

    _computeGranuleDescription: ->
      result = null
      return result unless @hasAtomData()
      if @id == 'C14758250-LPDAAC_ECS'
        console.log "DESCRIPTION: #{@granuleDatasource()?.granuleDescription() ? 'Collection only'}"
      @granuleDatasource()?.granuleDescription() ? 'Collection only'

    _computeOsddUrl: ->
      url = @osdd_url() ? @details()?.osdd_url
      url += "&clientId=#{config.cmrClientId}" if url
      url

    thumbnail: ->
      granule = @browseable_granule
      collection_id = @id for link in @links when link['rel'].indexOf('browse#') > -1
      if collection_id?
        "#{scalerUrl}/datasets/#{collection_id}?h=#{thumbnailWidth}&w=#{thumbnailWidth}"
      else if granule?
        "#{scalerUrl}/granules/#{granule}?h=#{thumbnailWidth}&w=#{thumbnailWidth}"
      else
        null

    granuleFiltersApplied: ->
      @granuleDatasource()?.hasQueryConfig()

    shouldDispose: ->
      result = !@granuleFiltersApplied()
      collections.remove(this) if result
      result

    makeRecent: ->
      id = @id
      if id? && !@featured
        ajax
          dataType: 'json'
          url: "/collections/#{id}/use.json"
          method: 'post'
          success: (data) ->
            @featured = data

    granuleDatasourceName: ->
      datasource = @getValueForTag('datasource')
      if datasource
        return datasource
      else if @has_granules
        return "cmr"
      else
        return null

    granuleRendererNames: ->
      renderers = @getValueForTag('renderers')
      if renderers
        return renderers.split(',')
      else if @has_granules
        return ["cmr"]
      else
        return []

    _visibilityChange: (visible) =>
      # TODO: Visibility continues to be too coupled to collections
      action = if visible then 'startSearchView' else 'endSearchView'
      @notifyRenderers(action)

    destroy: ->
      @_unloadDatasource()
      @_unloadRenderers()
      super()

    notifyRenderers: (action) ->
      @_loadRenderers()
      if @_loading
        @_pendingRenderActions.push(action)
      else
        for renderer in @_renderers
          renderer[action]?()

    _loadRenderers: ->
      names = @granuleRendererNames()
      loaded = names.join(',')
      if loaded.length > 0 && loaded != @_currentRenderers
        @_loading = true
        @_currentRenderers = loaded
        @_unloadRenderers()
        expected = names.length
        onload = (PluginClass, facade) =>
          renderer = new PluginClass(facade, this)
          @_renderers.push(renderer)
          for action in @_pendingRenderActions
            renderer[action]?()

        oncomplete = =>
          expected -= 1
          if expected == 0
            @_loading = false
            @_pendingRenderActions = []

        for renderer in names
          edscplugin.load "renderer.#{renderer}", onload, oncomplete

    _unloadRenderers: ->
      renderer.destroy() for renderer in @_renderers
      @_renderers = []

    _loadDatasource: ->
      desiredName = @granuleDatasourceName()
      if desiredName && @_currentName != desiredName
        @_currentName = desiredName
        @_unloadDatasource()
        onload = (PluginClass, facade) =>
          datasource = new PluginClass(facade, this)
          @_currentName = desiredName
          @_unloadDatasource()
          @granuleDatasource(@disposable(datasource))

        oncomplete = =>
          if @_datasourceListeners
            for listener in @_datasourceListeners
              listener(@granuleDatasource())
            @_datasourceListeners = null

        edscplugin.load "datasource.#{desiredName}", onload, oncomplete

    _unloadDatasource: ->
      if @granuleDatasource()
        @granuleDatasource().destroy()
        @granuleDatasource(null)

    granuleDatasourceAsync: (callback) ->
      if !@canFocus() || @granuleDatasource()
        callback(@granuleDatasource())
      else
        @_datasourceListeners ?= []
        @_datasourceListeners.push(callback)

    getValueForTag: (key) ->
      if @tags()
        for [k, v] in @tags()
          return v if k == "#{config.cmrTagNamespace}#{key}"
      null

    canFocus: ->
      @hasAtomData() && @granuleDatasourceName()

    fromJson: (jsonObj) ->
      @json = jsonObj

      @short_name = ko.observable('N/A') unless jsonObj.short_name

      @hasAtomData(jsonObj.short_name?)
      @_setObservable('gibs', jsonObj)
      @_setObservable('opendap', jsonObj)
      @_setObservable('modaps', jsonObj)
      @_setObservable('osdd_url', jsonObj)

      @nrt = jsonObj.collection_data_type == "NEAR_REAL_TIME"
      @granuleCount(jsonObj.granule_count)

      for own key, value of jsonObj
        this[key] = value unless ko.isObservable(this[key])

      @_loadDatasource()
      @granuleDatasource()?.updateFromCollectionData?(jsonObj)

    _setObservable: (prop, jsonObj) =>
      this[prop] ?= ko.observable(undefined)
      this[prop](jsonObj[prop] ? this[prop]())

    _isCwic: (jsonObj) ->
      if jsonObj.tags?
        return true for tag in jsonObj.tags when tag[1].toLowerCase() == 'cwic'
      false

  exports = Collection
