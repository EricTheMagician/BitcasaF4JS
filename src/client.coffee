BASEURL = 'https://developer.api.bitcasa.com/v1/'

class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @accessToken = null) ->

  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (@code) ->

module.exports.client = BitcasaClient
