const AWS = require("aws-sdk");
const moment = require("moment");
const ms = require("ms");
const fetch = require('node-fetch');
const debug = require('debug')('babysitter:backups');

const getBackupInfo = async (region, volumes) => {
  if (region === "msi") {
    return {
      count: 0,
      recent: [],
      mostRecent: null
    };
  } else {
    const ec2 = new AWS.EC2({ region });
    const { Snapshots } = await ec2
      .describeSnapshots({
        Filters: [
          { Name: "volume-id", Values: volumes.map(v => v.id) },
          // {
          //   Name: "start-time",
          //   Values: [
          //     `>${new Date(new Date().getTime() - ms("29d"))
          //       .toISOString()
          //       .replace("Z", "")}`
          //   ]
          // }
        ]
      })
      .promise();
    snapshots = Snapshots.sort((a, b) => a.StartTime - b.StartTime).reverse();
    const sda1 = volumes.find(v => v.device === "/dev/sda1").id;
    backups = snapshots.filter(snapshot => snapshot.VolumeId === sda1);
    backups = backups.map(b => ({
      time: b.StartTime,
      state: b.State,
      agsErrors: b.Tags.find(t => t.Key === "agsErrors")
        ? parseInt(b.Tags.find(t => t.Key === "agsErrors").Value)
        : 0,
      agsServices: b.Tags.find(t => t.Key === "agsServices")
        ? parseInt(b.Tags.find(t => t.Key === "agsServices").Value)
        : 0
    }));
    let timeline = [];
    // get one backup per-day for the last 28 days
    let days = 28;
    let now = new Date();
    let i = 0;
    while (i < days) {
      day = moment()
        .endOf("day")
        .subtract("days", i);
      let dayBefore = moment()
        .endOf("day")
        .subtract("days", i + 1);
      let backup = backups.find(b => b.time < day && b.time > dayBefore);
      i += 1;
      if (backup) {
        timeline.push(backup);
      } else {
        timeline.push({ time: dayBefore, state: "missing" });
      }
    }

    return {
      count: Math.floor(snapshots.length / 2),
      recent: timeline,
      mostRecent: backups[0]
    };
  }
};

const makeBackup = async ({name, region, volumes, severe, mapServices, gpServices}) => {
  if (region !== 'msi') {
    const ec2 = new AWS.EC2({region});
    debug(`Creating backup for ${name}`);
    return Promise.all(volumes.map(async (volume) => {
      const Description = `${name} ${volume.device} Backup -- ${moment().format('MMMM Do YYYY, h:mm:ss a')}`
      debug(`About to run ${volume.id} ${Description}`);
      try {
        const snapshot = await ec2.createSnapshot({VolumeId: volume.id, Description}).promise();
        debug(`Tagging backups for ${name}`);
        await ec2.createTags({Resources: [snapshot.SnapshotId], Tags: [
          { Key: 'agsErrors', Value: (severe || 0).toString() },
          { Key: 'agsServices', Value: (0 + mapServices + gpServices).toString()}
        ]}).promise();
      } catch (e) {
        console.log(e);
        debug(e);
      }
    }));
  }
};

const clearOldSnapshots = async (region, volumes) => {};

/**
 * Snapshot ArcGIS Server instance volumes that have not yet been backed-up today
 * @param {Object} instances List of ArcGIS Server instances w/backup info
 */
const backup = async () => {
  debug("Fetch instances");
  const response = await fetch("http://babysitter.seasketch.org.s3-website-us-west-2.amazonaws.com/instances.json");
  const { instances, lastUpdated } = await response.json();
  const cutoffTime = new Date().getTime() - ms('24h');
  debug("Cutoff time " + cutoffTime);
  for (const instance of instances) {
    if (instance.backups && instance.backups.mostRecent && new Date(instance.backups.mostRecent.time).getTime() < cutoffTime) {
      debug(`Out of date backups for ${instance.name}`);
      await makeBackup(instance);
    }
  }
}

module.exports = {
  getBackupInfo,
  clearOldSnapshots,
  backup
};