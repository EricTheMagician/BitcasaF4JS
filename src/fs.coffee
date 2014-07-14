config = require('./config.json')
BitcasaClient = module.exports.client

#bitcasa client
client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
#get folder attributes in the background
client.getFolders()

getattr = (path, cb) ->
  return client.folderTree.get(path).getAttr(cb)
