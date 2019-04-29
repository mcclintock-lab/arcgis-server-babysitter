/**
 * Get list of domains in the SeaSketch gandi account.
 * No longer used by babysitter, but here for reference and 
 * future use.
 */
const ms = require('ms');
const xmlrpc = require('xmlrpc');
const debug = require('debug')('babysitter:domains');
const {promisify} = require('util');

const CACHE_INTERVAL = ms('5m');
const GANDI_KEY = process.env.GANDI_KEY;

let cache = null;

const getDomains = async () => {
  if (cache) {
    last = cache.time.getTime()
    since = Date.now() - last;  
    if (since < CACHE_INTERVAL) {
      debug("Gandi cache hit on domains");
    }
    return cache.value;
  } else {
    debug("Cache miss");
    const api = xmlrpc.createSecureClient({
      host: 'rpc.gandi.net',
      port: 443,
      path: '/xmlrpc/'
    });
    api.methodCall = promisify(api.methodCall);
    const {zone_id} = await api.methodCall("domain.info", [GANDI_KEY, 'seasketch.org']);
    const {version} = await api.methodCall("domain.zone.info", [GANDI_KEY, zone_id]);
    const domains = await api.methodCall("domain.zone.record.list", [GANDI_KEY, zone_id, version]);
    cache = {
      time: new Date(),
      value: domains
    };
    return domains;
  }
}

module.exports = getDomains;