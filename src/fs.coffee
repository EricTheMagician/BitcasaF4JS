BitcasaClient = module.exports.client
config = require('./config.json')

client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
