AWS = require('aws-sdk')
express = require 'express'
_ = require 'underscore'
async = require 'async'
request = require 'request'
config = require './config.json'
fs = require 'fs'
moment = require 'moment'
xmlrpc = require 'xmlrpc'

app = express()
app.configure () ->
  app.use express.static(__dirname + '/public')
  app.use express.bodyParser()

AWS.config.loadFromPath('./config.json')


cache = {
  regions: []
  staticServers: [
    "data1.seasketch.org",
    "data2.seasketch.org",
    "data3.seasketch.org",
    "data4.seasketch.org",
    "data5.seasketch.org"
  ]
}

getAGSToken = (instance, next) ->
  base = instance.name
  url = "https://#{base}/arcgis/admin/generateToken"
  form =
      username: config.agsAdmin.username
      password: config.agsAdmin.password
      client: 'requestip'
      expiration: 10
      f: 'json'        
  request.post url, {form: form, timeout: 4000}, (err, res, body) ->
      if err then return next err
      try
        body = JSON.parse body
      catch e
        console.log "AGS token parse:", e, body
        return next e
      if body?.messages?
        next new Error(url + ': ' + body.messages[0])
      else
        next null, body.token

getDomains = (next) ->
  console.time('getDomains')
  last = cache.domains.time.getTime()
  since = Date.now() - last;
  if since < cache.domains.interval
    console.log "Cache hit on getDomains..."
    next null, cache.domains.value
  else
    console.log "Cache miss on getDomains, getting..."
    api = xmlrpc.createSecureClient({
      host: 'rpc.gandi.net',
      port: 443,
      path: '/xmlrpc/'
    })
    params = [config.gandiKey, 'seasketch.org']
    api.methodCall 'domain.info', params, (err, value) ->
      if err or !value?.zone_id?
        console.timeEnd('getDomains')
        next err
      else
      params[1] = value.zone_id
      api.methodCall 'domain.zone.info', params, (err, value) ->
        if err or !value.version
          console.timeEnd('getDomains')
          next err
        else
          params[2] = value.version
          api.methodCall 'domain.zone.record.list', params, (err, value) ->
            if err
              console.timeEnd('getDomains')
              next err
            else
              console.timeEnd('getDomains')
              cache.domains.value = value
              cache.domains.time = Date.now()
              next err, value

addAGSInfo = (instance, next) ->
  getAGSToken instance, (err, token) ->
    if err
      console.log "Could not obtain token from #{instance.name}: ", err
      instance.notResponding = true
      next null, instance
    else
      addAGSVersion instance, token, (err) ->
        if err then return next err
        addAGSLogLevel instance, token, (err) ->
          if err then return next err
          addHostOS instance, token, (err) ->
            if err then return next err
            # grab number of services
            base = instance.name
            url = "http://#{base}/arcgis/admin/clusters/default/services" +
              "?token=#{token}&f=json"
            request.get url, (err, res, body) ->
              if err
                console.log 'ags token fetch didnt work for url', instance.name, url
                next null, {}
              else
                data = JSON.parse body
                instance.services = data.services?.length
                instance.mapServices = _.filter(data.services, (svc) -> svc.type is 'MapServer').length
                instance.gpServices = _.filter(data.services, (svc) -> svc.type is 'GPServer').length
                # grab number and sampling of WARNING and SEVERE errors
                url = "http://#{base}/arcgis/admin/logs/query" +
                  "?token=#{token}&" +
                  "filter=%7B%7D&level=WARNING&pageSize=1000&" +
                  "endTime=#{(new Date()).getTime() - (1000 * 60 * 60 * 24)}"
                instance.agsErrorsLink = url + '&f=html'
                request.get url + '&f=json', (err, res, body) ->
                  if err
                    console.log 'trouble getting arcgis logs for #{instance.name}'
                    next null, {}
                  else
                    data = JSON.parse body
                    if _.isArray data?.logMessages
                      messages = data.logMessages
                      warnings = messages.filter (m) -> m.type is 'WARNING'
                      severe = messages.filter (m) -> m.type is 'SEVERE'
                      instance.warnings = warnings.length
                      instance.severe = severe.length
                      instance.exampleErrors = severe.slice(0, 5)
                    next null, instance

addAGSVersion = (instance, token, cb) ->
  base = instance.name
  url = "http://#{base}/arcgis/admin?token=#{token}&f=json"
  request.get url, (err, res, body) ->
    if err
      console.log 'ags version fetch didnt work for url', instance.name, url
      cb null, {}
    else
      data = JSON.parse body
      instance.version = data.fullVersion
      cb null, instance

addAGSLogLevel = (instance, token, cb) ->
  base = instance.name
  url = "http://#{base}/arcgis/admin/logs/settings?token=#{token}&f=json"
  request.get url, (err, res, body) ->
    if err
      console.log 'ags log settings fetch didnt work for url', instance.name, url
      cb null, {}
    else
      data = JSON.parse body
      instance.loglevel = data.settings.logLevel
      cb null, instance

addHostOS = (instance, token, cb) ->
  base = instance.name
  url = "http://#{base}/arcgis/admin/machines?token=#{token}&f=json"
  request.get url, (err, res, body) ->
    if err
      console.log 'ags machines fetch didnt work for url', instance.name, url
      cb null, {}
    else
      data = JSON.parse body
      firstMachine = data.machines[0].machineName
      url = "http://#{base}/arcgis/admin/machines/#{firstMachine}?token=#{token}&f=json"
      request.get url, (err, res, body) ->
        if err
          console.log 'ags machines fetch didnt work for url', instance.name, url
          cb null, {}
        else
          data = JSON.parse body
          instance.hostos = data.platform
          instance.uptime = Math.floor(moment.duration(Date.now() - data.ServerStartTime).asDays())
          cb null, instance


addBackupInfo = (instance, next) ->
  ec2 = new AWS.EC2(region: instance.region)
  params =
    Filters: [
      { Name: 'volume-id', Values: instance.volumes.map((v) -> v.id) }
    ]
  ec2.describeSnapshots params, (err, results) ->
    snapshots = _.sortBy results.Snapshots, (snapshot) ->
      snapshot.StartTime
    snapshots.reverse()
    sda1 = _.find(instance.volumes, (v) -> v.device is '/dev/sda1').id
    backups = snapshots.filter (snapshot) -> snapshot.VolumeId is sda1
    backups = backups.map (b) -> {
      time: b.StartTime
      state: b.State
      agsErrors: parseInt(_.find(b.Tags, (t) -> t.Key is 'agsErrors')?.Value)
      agsServices: parseInt(_.find(b.Tags, (t) -> t.Key is 'agsServices')?.Value)
    }
    timeline = []
    # get one backup per-day for the last 28 days
    days = 28
    now = new Date()
    i = 0
    while i < days
      day = moment().endOf('day').subtract('days', i)
      dayBefore = moment().endOf('day').subtract('days', i + 1)
      backup = _.find backups, (b) -> b.time < day and b.time > dayBefore
      i += 1
      if backup
        timeline.push backup
      else
        timeline.push {time: dayBefore, state: 'missing'}

    instance.backups = {
      count: Math.floor(snapshots.length / 2)
      recent: timeline
    }
    next err, instance

getInstances = (region='us-west-2', next) ->
  
  ec2 = new AWS.EC2(region: region)
  ec2.describeInstances (err, data) ->
    if err
      next err
    else
      instances = parseInstances(data, region)
      instances = instances.filter (i) -> i.state is 'running'
      async.each instances, addBackupInfo, (err) ->
        if err
          next err
        else
          async.each instances, addAGSInfo, (err) ->
            async.each instances, (instance, callback) ->
              filepath = __dirname + "/pemUploads/#{instance.pem}.pem"
              fs.exists filepath, (result) ->
                instance.hasPem = result
                callback null
            , (err) ->
              next err, instances


getStaticServers = (cb) ->
  instances = []
  for s in cache.staticServers
    instances.push {name: s, hasPem: false, region: 'msi', availabilityZone: 'msi'} 
  async.each instances, addAGSInfo, (err) ->
    if err then return cb err
    cb null, instances

parseInstances = (data, region) ->
  instances = []
  for reservation in data.Reservations
    for instance in reservation.Instances
      name = _.find(instance.Tags, (t) -> t.Key is 'Name')?.Value
      instanceData = JSON.stringify(instance)
      if /arcgis/.test(instanceData) or /arcserver/.test(instanceData) or /data.*-/.test(instanceData) or /gp.*-/.test(instanceData) or /gp\d/.test(instanceData) or /minke.*/.test(instanceData) or /fin.*/.test(instanceData)
        instances.push {
          id: instance.InstanceId
          name: name
          pem: instance.KeyName
          state: instance.State.Name
          publicDNS: instance.PublicDnsName
          region: region
          availabilityZone: instance.Placement.AvailabilityZone
          volumes: instance.BlockDeviceMappings.map (block) -> 
            {
              device: block.DeviceName
              id: block.Ebs.VolumeId
            }
        }
  return instances

createBackup = (instance, next) ->
  ec2 = new AWS.EC2(region: instance.region)
  console.log 'createBackup', instance
  if instance.availabilityZone is 'msi'
    console.log "Cannot backup MSI-hosted instances"
    return next()
  async.map instance.volumes, (volume, callback) ->
    desc = "#{instance.name} #{volume.device} Backup -- #{moment().format('MMMM Do YYYY, h:mm:ss a')}"
    ec2.createSnapshot {VolumeId: volume.id, Description: desc}, callback
  , (err, snapshots) ->
    if err
      next err
    else
      async.each snapshots, (snapshot, callback) ->
        tags = [
          { Key: 'agsErrors', Value: instance.severe.toString() }
          { Key: 'agsServices', Value: instance.services.toString()}
        ]
        ec2.createTags {Resources: [snapshot.SnapshotId], Tags: tags}, 
          callback
      , next

getAllInstances = (next) ->
  AWS.config.update(region: 'us-west-2')
  ec2 = new AWS.EC2()
  ec2.describeRegions (err, regions) ->
    if err then return next err
    regions = regions.Regions?.map (region) -> region.RegionName
    async.concat regions, (region, callback) ->
      getInstances region, (err, instances) ->
        if err then console.log 'err getting instances', region, err
        else callback(null, instances or [])
    , (err, allInstances) ->
      if err then return next err
      getStaticServers (err, staticinstances) ->
        if err then return next err
        next null, _.union(allInstances, staticinstances)

app.use (err, req, res, next) ->
  res.send 500, 'Something broke!'

app.get '/data', (req, res, next) ->
  res.json {instances: instanceData, lastUpdated: lastUpdated}

app.get '/', (req, res, next) ->
  fs.readFile './public/index.html', "binary", (err, file) ->
    if err
      next err
    else
      res.writeHead(200)
      res.write(file, "binary")
      res.end()

app.post '/backup', (req, res, next) ->
  instance = req.body
  createBackup instance, (err, results) ->
    if err
      next err
    else
      res.json {okay: true}

app.get '/healthcheck', (req, res, next) ->
  res.send 200, "I'm here"

app.listen 4002

instanceData = []
lastUpdated = new Date(0)

setInterval () ->
  getAllInstances (err, allInstances) ->
    if err
      console.log 'Error getting all instances for backup'
      console.log err
    else
      for instance in allInstances
        backups = instance.backups?.recent.filter (b) -> b.state != 'missing'
        time = moment(backups?[0]?.time)
        if !backups?.length or moment().diff(time, 'days') != 0
          console.log instance.name, 'needs backing up...'
          createBackup instance, (err) ->
            if err
              console.log "Could not trigger backup on #{instance.name}: ", err
            else
              console.log "Triggered backup on #{instance.name}"
, 60 * 1000 * 60

retrieveInstanceData = () ->
  getAllInstances (err, allInstances) ->
    if err
      console.log 'Error getting all instances'
      console.log err
    else
      instanceData = allInstances
      lastUpdated = new Date()

setInterval retrieveInstanceData, 2 * 60 * 1000

retrieveInstanceData()

reportBackups = () ->
  console.log 'report backups'
  getAllInstances (err, allInstances) ->
    if err
      console.log 'Error getting all instances for reporting to slack'
      console.log err
    else
      backupStats = []
      for instance in allInstances
        backups = instance.backups?.recent.filter (b) -> b.state != 'missing'
        time = moment(backups?[0]?.time)
        if !backups?.length
          backupStats.push {
            name: instance.name
            lastBackup: 'unknown'
          }
        else
          backupStats.push {
            name: instance.name
            lastBackup: "#{moment().diff(time, 'hours')} hours ago"
          }
      message =
        text: "Reminder, you poor saps have #{allInstances.length} instances of ArcGIS Server running. <http://babysitter.seasketch.org/|Details>"
      request.post {uri: config.slack, json: message}, (err, httpResponse, body) ->
        console.log(err) if err
        json = 
          pretext: "Last backed up..."
          fallback: (backupStats.map (s) -> "#{s.name}: #{s.lastBackup}").join(', ')
          color: "#c62a06"
          fields: backupStats.map (s) -> {title: s.name, value: s.lastBackup, short: true}
        request.post
          uri: config.slack
          json: json
        , (err, res, body) ->
          console.log(err) if err


setInterval reportBackups, 1000 * 60 * 60 * 24

reportBackups()