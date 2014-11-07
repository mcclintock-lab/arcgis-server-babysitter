class Server extends Backbone.Model

class Servers extends Backbone.Collection
  model: Server
  url: '/data'
  comparator: (server) ->
    server.get('region') + server.get('name')
  parse: (response) ->
    @lastUpdated = new Date(response.lastUpdated)
    response.instances

class ServerItem extends Backbone.View
  className: 'serverItem'
  events:
    "click a[rel=backup]":        'backup'
    "click a[rel=ssh]":           'ssh'
  bindings:
    "h2 a.label":                     
      observe: ["name", "domain"]
      onGet: () ->
        @model.get('domain') or @model.get('name')
      attributes: [
        {
          name: 'href'
          observe: ['domain', 'loadBalancer', 'publicDNS']
          onGet: () ->
            if @model.get('domain')
              "http://#{@model.get('domain')}.seasketch.org/arcgis/rest/services"
            else if @model.get('loadBalancer')
              @model.get('loadBalancer') + '/arcgis/rest/services'
            else
              "http://#{@model.get('publicDNS')}:6080/arcgis/rest/services"
        }
      ]
    "h2 a.manager":
      attributes: [
        {
          name: 'href'
          observe: ['domain', 'loadBalancer', 'publicDNS']
          onGet: () ->
            if @model.get('domain')
              "http://#{@model.get('domain')}.seasketch.org/arcgis/manager/"
            else if @model.get('loadBalancer')
              @model.get('loadBalancer') + '/arcgis/manager/'
            else
              "http://#{@model.get('publicDNS')}:6080/arcgis/manager/"
        }
      ]    
    ".zone":                  "availabilityZone"
    ".state":                 
      observe: "state"
      attributes: [
        {
          name: 'data-state'
          observe: 'state'
        }
      ]
    ".services":              
      observe: "services"
      attributes: [
        {
          name: 'data-warning'
          observe: "services"
          onGet: (count) ->
            if count > 50
              true
            else
              false
        }
      ]
    "[rel=pem]":
      observe: ["pem", "hasPem"]
      visible: () ->
        @model.get('hasPem')
      updateView: true
      onGet: () -> "#{@model.get('pem')}.pem"
      attributes: [
        {
          name: 'download'
          observe: 'pem'
          onGet: (v) -> "#{v}.pem"
        }
        {
          name: 'href'
          observe: 'pem'
          onGet: (v) -> "/pem/#{v}.pem"
        }
      ]
    ".missing-pem":
      observe: ["hasPem", "pem"]
      visible: () -> !@model.get('hasPem')
      updateView: true
      onGet: () ->
        "Missing #{@model.get('pem')}.pem. Drag file to this box to upload"
    '[rel="manager"]':
      attributes: [
        {
          name: 'href'
          observe: 'loadBalancer'
          onGet: (v) ->
            "http://#{v}/arcgis/manager/"
        }
      ]
    '[rel="warnings"]':
      observe: 'warnings'
      attributes: [
        {
          name: 'href'
          observe: 'agsErrorsLink'
        }
      ]
    '[rel="severe"]':
      observe: 'severe'
      attributes: [
        {
          name: 'href'
          observe: 'agsErrorsLink'
        }
      ]

  constructor: (@model) ->
    @model.on 'change:backups', @drawBackups
    window.app.servers.on 'remove', (model) =>
      if model is @model
        @remove()
    super()

  render: () ->
    @$el.html """
      <h2><a target="_blank" class="label" href="#"></a><a target="_blank" class="manager" href="#">manager</a></h2>
      <span class="zone"></span>
      <span class="state"></span>
      <span class="services"></span>
      <a target="_blank" rel="warnings" href=""></a>
      <a target="_blank" rel="severe" href=""></a>
      <a rel="pem" href="#" download></a>
      <span class="missing-pem">Missing pem. Drag .pem file here to upload.</span>
      <a href="#" rel="ssh">ssh</a>
      <h3>backups <a href="#" rel="backup">backup now</a></h3>
      <div class="backups"></div>
    """
    @stickit()
    dropzone = new Dropzone(@el, { url: "/pem/" + @model.get('pem')})
    dropzone.on 'dragstart', () =>
      console.log 'dragstart'
      @$el.addClass 'dragstart'
    dropzone.on 'dragover', () =>
      console.log 'dragover'
      @$el.addClass 'dragover'
    dropzone.on 'dragleave', () =>
      @$el.removeClass 'dragover dragstart'
    dropzone.on 'dragleave', () =>
      @$el.removeClass 'dragover dragstart'
    dropzone.on 'complete', (data, a) =>
      @$el.removeClass 'dragover dragstart'
      if data.accepted
        @model.set 'hasPem', true
      else
        alert "Failed to upload .pem"

    @drawBackups()

  drawBackups: () =>
    html = ""
    for backup in (@model.get('backups')?.recent or [])
      status = "ok"
      title = "okay"
      if backup.state is 'missing'
        status = "missing"
        title = "missing backup"
      else if backup.agsErrors and backup.agsErrors > 20
        status = "warning"
        title = ">20 severe errors in 24 hours"
      if backup.agsErrors and backup.agsErrors > 80
        status = "danger"
        title = ">80 severe errors in 24 hours"
      unless backup.state is 'missing'
        title += " - " + backup.time
        title += " (services: #{backup.agsServices}, errors: #{backup.agsErrors}" 
      html += """
        <div class="backup" title="#{title}" data-status="#{status}"></div>
      """
    @$('.backups').html html

  backup: () ->
    data = JSON.stringify(@model.toJSON())
    @$('[rel=backup]').hide()
    $.ajax({
      type: "POST"
      url: '/backup'
      data: data
      dataType: 'json'
      contentType:"application/json; charset=utf-8"
      success: () =>
        @$('[rel=backup]').show()
        alert "Created backup"
      error: () =>
        @$('[rel=backup]').show()
        alert "Problem creating backup"
    })

  ssh: () ->
    cmd = "ssh -i ~/#{@model.get('pem')}.pem ubuntu@#{@model.get('publicDNS')}"
    window.prompt "Download the pem file and connect to this server using the following command. Make sure that the ssh port is open on this server (via the aws console Security Groups configuration).", cmd

window.app = window

$(document).ready () ->
  app.servers = new Servers()
  app.servers.on 'request', () ->
    $('.icon-spin3').addClass 'animate-spin'    
  app.servers.on 'sync', () ->
    $('.icon-spin3').removeClass 'animate-spin'
    $('.lastUpdated').text "Last Updated #{app.servers.lastUpdated}"
  $('.icon-spin3').click () ->
    window.app.servers.fetch()

  app.servers.fetch()


  app.servers.on 'add', (server) ->
    view = new ServerItem(server)
    $('.servers').append view.el
    view.render()

  window.setInterval (() -> window.app.servers.fetch()), 5 * 60 * 1000
