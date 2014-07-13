chai = require "chai"
expect = chai.expect

modules = require '../src/client.coffee'
config = require '../build/config.json'
BitcasaClient = modules.client


describe 'BitcasaClient instance', ->
  it 'default access token should be null', ->
    client = new BitcasaClient()
    expect(client).to.exist
    expect(client.accessToken).to.equal(null)

  it 'should have the right login url', ->
    client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, config.accessToken
    expect(client.loginUrl()).to.equal("https://developer.api.bitcasa.com/v1/oauth2/authenticate?client_id=#{config.clientId}&redirect_url=#{config.redirectUrl}")

  it.skip 'should restpect rate limits and get root', (done) ->
    client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, config.accessToken
    expect(client.rateLimit.getTokensRemaining()).to.equal(180)
    client.getRoot done
    expect(client.rateLimit.getTokensRemaining()).to.be.within(179,180)
