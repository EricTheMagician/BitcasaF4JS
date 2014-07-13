chai = require "chai"
expect = chai.expect

modules = require '../src/client.coffee'
BitcasaClient = modules.client


describe 'BitcasaClient instance', ->
  client = new BitcasaClient()
  it 'default access token should be null', ->
    expect(client.accessToken).to.equal(null)
