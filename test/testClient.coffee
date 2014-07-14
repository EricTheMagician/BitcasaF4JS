chai = require "chai"
expect = chai.expect

modules = require '../src/client.coffee'
config = require '../build/config.json'
BitcasaClient = modules.client


describe 'BitcasaClient instance', ->
  describe 'after creation', ->
    it 'default access token should be null', ->
      client = new BitcasaClient()
      expect(client).to.exist
      expect(client.accessToken).to.equal(null)

    it 'should have the right login url', ->
      client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, config.accessToken
      expect(client.loginUrl()).to.equal("https://developer.api.bitcasa.com/v1/oauth2/authenticate?client_id=#{config.clientId}&redirect_url=#{config.redirectUrl}")

  describe 'when in use', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
    it.skip 'should restpect rate limits and get root with infinite drive', (done) ->
      expect(client.rateLimit.getTokensRemaining()).to.equal(180)
      client.getRoot ()->
        # console.log client.folderTree.get('/')
        expect(client.folderTree.get('/').children).to.include.members(['/Bitcasa Infinite Drive'])
        done()
      expect(client.rateLimit.getTokensRemaining()).to.be.closeTo(179,0.5)
    it.skip 'should get folders', (done) ->
      client.getFolders #done

    it.skip 'should be able to download files properly', (done)->
      client.download('/m__k6DI5SGOHivKQlBuqyw/YnZAIPkZT2epFyagYiP9WQ/gi9LDgHzRRGydOxuFDCQsw','file.ext',0,1024*1024*10,1024*1024*10, done)
