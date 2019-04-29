/**
 * getInstances()
 * Retrieves a list of active ArcGIS Server instances running on the
 * lab's AWS infrastructure, as well as a hardcoded list of MSI servers.
 */
const AWS = require("aws-sdk");
const debug = require("debug")("babysitter:getInstances");

const isAGS = instance => {
  // return instance;
  const s = JSON.stringify(instance);
  return (
    /arcgis/.test(s) ||
    /arcserver/.test(s) ||
    /data/.test(s) ||
    /gp\./.test(s) ||
    /minke\./.test(s) ||
    /fin\./.test(s)
  );
};

const getInstancesForRegion = async (RegionName) => {
  debug(RegionName);
  let instances = [];
  const ec2 = new AWS.EC2({ region: RegionName });
  let Reservations = [];
  try {
    const data = await ec2.describeInstances().promise();
    Reservations = data.Reservations;
  } catch (e) {
    debug(`Could not list instances in ${RegionName}`);
  }
  for (var reservation of Reservations) {
    instances = instances.concat(
      reservation.Instances.map(instance => {
        const nameTag = instance.Tags.find(t => t.Key === "Name");
        return {
          region: RegionName,
          id: instance.InstanceId,
          name: nameTag ? nameTag.Value : "",
          pem: instance.KeyName,
          state: instance.State.Name,
          availabilityZone: instance.Placement.AvailabilityZone,
          volumes: instance.BlockDeviceMappings.map(block => ({
            device: block.DeviceName,
            id: block.Ebs.VolumeId
          }))
        };
      })
    );
  }
  return instances;
}

const getInstances = async () => {
  const { Regions } = await new AWS.EC2().describeRegions().promise();
  const regionInstances = await Promise.all(Regions.map(({RegionName}) => getInstancesForRegion(RegionName)));
  let instances = [].concat.apply([], regionInstances);
  return instances
    .filter(i => isAGS(i))
    .concat(
      [
        "data1.seasketch.org",
        "data2.seasketch.org",
        "data3.seasketch.org",
        "data4.seasketch.org",
        "data5.seasketch.org"
      ].map(name => ({
        region: "msi",
        availabilityZone: "msi",
        id: name,
        name,
        pem: "n/a",
        state: "running"
      }))
    );
};

module.exports = getInstances;
