const getInstances = require("./src/getInstances");
const getAGSInfo = require("./src/getAGSInfo");
const { getBackupInfo, backup } = require("./src/backups");
const AWS = require('aws-sdk');
const s3 = new AWS.S3();
const debug = require("debug")("babysitter:inspectInstances");
const ms = require('ms');

const inspectInstances = async () => {
  const instances = await getInstances();
  return Promise.all(
    instances.map(async instance => {
      debug(`getting ags info for ${instance.name}`);
      const agsInfo = await getAGSInfo(`https://${instance.name}`);
      debug(`getting backup info for ${instance.name}`);
      const backupInfo = await getBackupInfo(instance.region, instance.volumes);
      return {
        ...instance,
        ...agsInfo,
        backups: backupInfo
      };
    })
  ).then(results =>
    results.sort((a, b) =>
      a.availabilityZone.localeCompare(b.availabilityZone)
    )
  ).then(instances => ({ instances, lastUpdated: new Date() }));
};

module.exports.updateInstanceInfo = async event => {
  const info = await inspectInstances();
  await s3.putObject({
    Bucket: 'babysitter.seasketch.org',
    Key: 'instances.json',
    Body: JSON.stringify(info),
    ContentType: "application/json",
    CacheControl: 'max-age=300',
    Expires: new Date(new Date().getTime() + ms('5m'))
  }).promise();
  return {
    message: `Success. https://babysitter.seasketch.org.s3-website-us-west-2.amazonaws.com/instances.json`
  };
};

module.exports.backup = async () => {
  await backup();
  return {
    message: `Backup success`
  };
};