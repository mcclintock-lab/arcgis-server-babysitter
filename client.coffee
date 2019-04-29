class Server extends Backbone.Model

class Servers extends Backbone.Collection
  model: Server
  url: './instances.json'
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
              "https://#{@model.get('name')}/arcgis/rest/services"
        }
      ]
    "h2 a.manager":
      attributes: [
        {
          name: 'href'
          observe: ['domain', 'loadBalancer', 'publicDNS']
          onGet: () ->
              "https://#{@model.get('name')}/arcgis/manager/"
        }
      ]    
    ".zone":                  "availabilityZone"
    ".version":                  "version"
    ".hostos":                  "hostos"
    ".uptime":                  "uptime"
    ".mapservices":           "mapServices"
    ".gpservices":           "gpServices"
    ":el":
      observe: "healthy"
      update: ($el, val) ->
        $el.attr('data-healthy', val)
      onGet: (healthy) ->
        if healthy
          "healthy"
        else
          "unhealthy"
    ".healthy":
      observe: "healthy"
      onGet: (healthy) ->
        if healthy
          "healthy"
        else
          "UNHEALTHY!"
    ".loglevel":
      observe: "loglevel"
      attributes: [
        {
          name: 'data-warning'
          observe: "loglevel"
          onGet: (lvl) ->
            if lvl is "DEBUG"
              true
            else
              false
        }
      ]

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
    '[rel="manager"]':
      attributes: [
        {
          name: 'href'
          observe: 'loadBalancer'
          onGet: (v) ->
            "https://#{v}/arcgis/manager/"
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
    @$el.addClass 'col-xl-3'
    @$el.html """
      <h2><a target="_blank" class="label" href="#"></a><a target="_blank" class="manager" href="#">manager</a></h2>
      <span class="healthy"></span>
      <span class="version"></span>
      <span class="hostos small"></span>
      <span class="uptime"></span>
      <span class="zone"></span>
      <span class="state"></span>
      <span class="services"></span>
      <span class="mapservices"></span>
      <span class="gpservices"></span>
      <span class="loglevel"></span>
      <a target="_blank" rel="warnings" href=""></a>
      <a target="_blank" rel="severe" href=""></a>
      <h3>backups</h3>
      <div class="backups"></div>
    """
    @stickit()
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
