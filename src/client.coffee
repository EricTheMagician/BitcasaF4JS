BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;

#for mocha testing
if module.export == undefined
  r = require './folder.coffee'
  BitcasaFolder = r.folder
else
  BitcasaFolder = module.export.folder

class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @accessToken = null) ->
    @rateLimit = new RateLimiter 180, 'minute'
    @folderTree = {}
    @bitcasaTree = {}
    if @accessToken != null
      @setRest()

  setRest: ->
    @client = new Client
    @client.registerMethod('getRootFolder', "#{BASEURL}folders/?access_token=#{@accessToken}", "GET")



  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (code) ->
    url = "#{BASEURL}oauth2/access_token?secret=#{@secret}&code=#{code}"
    new Error("Not implemented")

  getRoot: (cb) ->
    client = @
    callback = (data,response) ->
      BitcasaFolder.parseFolder(data,response, client,cb)
    @rateLimit.removeTokens 1, (err, remaining) ->
      client.client.methods.getRootFolder callback


  getFolders: (cb) ->
    @rateLimit.removeTokens 1, (err,remainingRequests) ->
      if typeof(cb) == typeof(Function)
        cb()
module.exports.client = BitcasaClient
