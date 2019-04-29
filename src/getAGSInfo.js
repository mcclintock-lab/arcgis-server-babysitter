const fetch = require("node-fetch");
const { URLSearchParams } = require("url");
const debug = require("debug")("babysitter:getAGSServerInfo");

/**
 * getAGSInfo()
 * Get version, services, and host information for a ArcGIS Server
 * Instance
 */
const getAGSInfo = async baseUrl => {
  let platformInfo, serviceCounts = {};
  let version = null;
  let healthy = true;
  let logLevel = '';
  let logs = {};
  try {
    debug("get token");
    const token = await getToken(baseUrl);
    version = await getVersion(baseUrl, token);
    serviceCounts = await getServiceCounts(baseUrl, token);
    platformInfo = await getPlatformInfo(baseUrl, token);
    logLevel = await getLogLevel(baseUrl, token);
    logs = await getLogMessages(baseUrl, token);
  } catch(e) {
    console.error(e);
    healthy = false;
  }
  if (logs.severe && logs.severe > 70) {
    healthy = false;
  }
  return {
    ...platformInfo,
    ...serviceCounts,
    version,
    healthy,
    logLevel,
    ...logs
  };
};

const getToken = async baseUrl => {
  const url = `${baseUrl}/arcgis/admin/generateToken`;
  const params = {
    username: process.env.SERVER_USERNAME,
    password: process.env.SERVER_PASSWORD,
    client: "requestip",
    expiration: 10,
    f: "json",
    referer: "babysitter.seasketch.org"
  };
  const form = new URLSearchParams();
  for (const key of Object.keys(params)) {
    form.append(key, params[key]);
  }
  try {
    const response = await fetch(url, {
      method: "post",
      body: form,
      headers: {
        Accept: "application/json",
        Referer: "babysitter.seasketch.org"
      }
    });
    const json = await response.json();
    return json.token;      
  } catch (e) {
    throw new Error(`${baseUrl} responded with an error to the generateToken request`);
  }
};

const getVersion = async (baseUrl, token) => {
  debug("get version info");
  const response = await fetch(
    `${baseUrl}/arcgis/admin?token=${token}&f=json`
  );
  const { fullVersion } = await response.json();
  return fullVersion;
}

const getServiceCounts = async (baseUrl, token) => {
  debug("get service counts");
  const response = await fetch(
    `${baseUrl}/arcgis/admin/clusters/default/services?token=${token}&f=json`
  );
  const { services } = await response.json();
  if (services) {
    return {
      gpServices: services.filter(s => s.type === "GPServer").length,
      mapServices: services.filter(s => s.type === "MapServer").length
    };
  } else {
    return {
      gpServices: 0,
      mapServices: 0
    }
  }
}

const getPlatformInfo = async (baseUrl, token) => {
  debug("get machines");
  let response = await fetch(
    `${baseUrl}/arcgis/admin/machines?token=${token}&f=json`
  );
  const { machines } = await response.json();
  if (!machines || !machines.length) {
    throw new Error(`No machines attached to ${baseUrl}`)
  }
  debug("get host information");
  response = await fetch(
    `${baseUrl}/arcgis/admin/machines/${
      machines[0].machineName
    }?token=${token}&f=json`
  );
  const { ServerStartTime, platform } = await response.json();  
  return {
    startTime: new Date(ServerStartTime || 0),
    platform
  }
}

const getLogLevel = async (baseUrl, token) => {
  const response = await fetch(`${baseUrl}/arcgis/admin/logs/settings?token=${token}&f=json`);
  const { settings } = await response.json();
  return settings.logLevel;
}

const getLogMessages = async (baseUrl, token) => {
  const url = `${baseUrl}/arcgis/admin/logs/query?token=${token}&filter=%7B%7D&level=WARNING&pageSize=1000&endTime=${(new Date()).getTime() - (1000 * 60 * 60 * 24)}&f=json`;
  // instance.agsErrorsLink = url + '&f=html'
  const response = await fetch(url);
  const {logMessages} = await response.json();
  if (logMessages && logMessages.length) {
    return {
      warnings: logMessages.filter((m) => m.type === 'WARNING').length,
      severe: logMessages.filter((m) => m.type === 'SEVERE').length,
      exampleErrors: logMessages.filter((m) => m.type === 'SEVERE').slice(0, 5),
      agsErrorsLink: `${baseUrl}/arcgis/admin/logs/query?filter=%7B%7D&level=WARNING&pageSize=1000&endTime=${(new Date()).getTime() - (1000 * 60 * 60 * 24)}&f=html`
    }
  } else {
    return {
      warnings: 0,
      severe: 0,
      exampleErrors: []
    }
  }
}

module.exports = getAGSInfo;
