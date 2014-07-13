BASEURL = 'https://developer.api.bitcasa.com/v1/'

class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @accessToken = null) ->

  login_url: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirect_url}"

  authenticate: (@code) ->

module.exports.client = BitcasaClient
