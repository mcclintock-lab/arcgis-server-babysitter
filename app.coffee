AWS = require('aws-sdk')
express = require 'express'
_ = require 'underscore'
async = require 'async'
request = require 'request'
config = require './config.json'
fs = require 'fs'
path = require 'path'
moment = require 'moment'
xmlrpc = require 'xmlrpc'

app = express()
app.configure () ->
  app.use express.static(__dirname + '/public')
  app.use '/pem', express.static(__dirname + '/pemUploads')
  app.use express.bodyParser()

AWS.config.loadFromPath('./config.json')

getAGSToken = (instance, next) ->
  base = instance.loadBalancer or instance.publicDNS + ':6080'
  url = "http://#{base}/arcgis/admin/generateToken"
  form =
    form:
      username: config.agsAdmin.username
      password: config.agsAdmin.password
      client: 'requestip'
      expiration: 10
      f: 'json'        
  request
    .post url, form, (err, res, body) ->
      body = JSON.parse body
      if err
        next err
      else if body?.messages?
        next new Error(url + ': ' + body.messages[0])
      else
        next null, body.token

getDomains = (next) ->
  api = xmlrpc.createSecureClient({
    host: 'rpc.gandi.net',
    port: 443,
    path: '/xmlrpc/'
  })
  params = [config.gandiKey, 'seasketch.org']
  api.methodCall 'domain.info', params, (err, value) ->
    if err or !value?.zone_id?
      next err
    else
    params[1] = value.zone_id
    api.methodCall 'domain.zone.info', params, (err, value) ->
      if err or !value.version
        next err
      else
        params[2] = value.version
        api.methodCall 'domain.zone.record.list', params, (err, value) ->
          if err
            next err
          else
            next err, value

addAGSInfo = (instance, next) ->
  if instance.loadBalancer or instance.publicDNS
    getAGSToken instance, (err, token) ->
      if err
        next err
      else
        # grab number of services
        base = instance.loadBalancer or instance.publicDNS + ':6080'
        url = "http://#{base}/arcgis/admin/clusters/default/services" +
          "?token=#{token}&f=json"
        request.get url, (err, res, body) ->
          if err
            next err
          else
            data = JSON.parse body
            instance.services = data.services.length
            # grab number and sampling of WARNING and SEVERE errors
            url = "http://#{base}/arcgis/admin/logs/query" +
              "?token=#{token}&" +
              "filter=%7B%7D&level=WARNING&pageSize=1000&" +
              "endTime=#{(new Date()).getTime() - (1000 * 60 * 60 * 24)}"
            instance.agsErrorsLink = url + '&f=html'
            request.get url + '&f=json', (err, res, body) ->
              if err
                next err
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
  else
    # not accessible
    next null, instance

getLoadBalancers = (next) ->
  ec2 = new AWS.EC2()
  ec2.describeRegions (err, regions) ->
    if err
      next err
    else
      regions = regions.Regions?.map (region) -> region.RegionName
      async.concat regions, (region, callback) ->
        elb = new AWS.ELB(region: region)
        elb.describeLoadBalancers (err, data) ->
          callback err, data
      , (err, data) ->
        loadBalancers = []
        for result in data
          loadBalancers = loadBalancers.concat(
              result.LoadBalancerDescriptions or []
            )
        next null, loadBalancers.filter (lb) -> 
          /arcgis/.test lb.HealthCheck?.Target

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
  getDomains (err, domains) ->
    if err
      next err
    else
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
              getLoadBalancers (err, loadBalancers) ->
                if err
                  next err
                else
                  for instance in instances
                    lb = _.find loadBalancers, (lb) -> 
                      instance.id in lb.Instances.map((i) -> i.InstanceId)
                    instance.loadBalancer = lb?.DNSName
                async.each instances, addAGSInfo, (err) ->
                  for instance in instances
                    domain = _.find domains, (d) -> 
                      match = instance.loadBalancer?.toLowerCase() + '.'
                      d.value.toLowerCase() is match
                    if domain
                      instance.domain = domain.name
                  async.each instances, (instance, callback) ->
                    filepath = __dirname + "/pemUploads/#{instance.pem}.pem"
                    path.exists filepath, (result) ->
                      instance.hasPem = result
                      callback null
                  , (err) ->
                    next err, instances

parseInstances = (data, region) ->
  instances = []
  for reservation in data.Reservations
    for instance in reservation.Instances
      name = _.find(instance.Tags, (t) -> t.Key is 'Name')?.Value
      if /arcgis/.test JSON.stringify(instance)
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

app.use (err, req, res, next) ->
  res.send 500, 'Something broke!'

app.get '/data', (req, res, next) ->
  AWS.config.update(region: 'us-west-2')
  ec2 = new AWS.EC2(region: 'us-west-2')
  ec2.describeRegions (err, regions) ->
    if err
      next err
    else
      regions = regions.Regions?.map (region) -> region.RegionName
      async.concat regions, (region, callback) ->
        getInstances region, (err, instances) ->
          callback(err, instances)
      , (err, allInstances) ->
        if err
          next err
        else
          res.json allInstances

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

app.post '/pem/:filename', (req, res, next) ->
  fs.readFile req.files.file.path, (err, data) ->
    if err
      next err
    else
      newPath = __dirname + "/pemUploads/" + req.param('filename') + '.pem'
      fs.writeFile newPath, data, (err) ->
        if err
          next err
        else
          res.json {okay: true}  

app.get '/pem/:filename', (req, res, next) ->


app.listen 3002, 'localhost'

setInterval () ->
  console.log 'checking to see what needs backing up...'
  AWS.config.update(region: 'us-west-2')
  ec2 = new AWS.EC2()
  ec2.describeRegions (err, regions) ->
    if err
      next err
    else
      regions = regions.Regions?.map (region) -> region.RegionName
      async.concat regions, (region, callback) ->
        getInstances region, (err, instances) ->
          callback(err, instances)
      , (err, allInstances) ->
        if err
          next err
        else
          for instance in allInstances
            backups = instance.backups.recent.filter (b) -> b.state != 'missing'
            time = moment(backups?[0]?.time)
            if !backups?.length or moment().diff(time, 'days') != 0
              console.log instance.name, 'needs backing up...'
              createBackup(instance)
, 60 * 1000 * 60
