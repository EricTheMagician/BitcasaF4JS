chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
modules = require '../src/client.coffee'
config = require '../build/test.config.json'
fs = require 'fs'
BitcasaClient = modules.client
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
pth = require 'path'


logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'debug' }),
    ]
  })


describe 'BitcasaClient', ->

  it 'should have the right login url', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, 2*1024*1024)
    expect(client.loginUrl()).to.equal("https://developer.api.bitcasa.com/v1/oauth2/authenticate?client_id=#{config.clientId}&redirect_url=#{config.redirectUrl}")

  it 'should fail to validate an invalid accesToken', (done) ->
    client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, logger, "#{config.accessToken}sadfasdfasdf1", config.chunkSize, config.advancedChunks, config.cacheLocation
    cb = (err, data) ->
      if err
        done()
      else
        done(data)
    client.validateAccessToken(cb)

  it 'should validate a valid accessToken', (done) ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)
    cb = (err, data) ->
      console.log "validate callback"
      if err
        done(err)
      else
        done()
    client.validateAccessToken(cb)
  describe.only 'when in use', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)
    download = Future.wrap(client.download)
    fileContent = 'hello world.txt'

    it 'should load folders', (done)->
      client.loadFolderTree(false)
      setTimeout done, 3000

    it 'should be able to create directories', (done) ->
      folder = client.folderTree.get("/Bitcasa Infinite Drive")
      expect(folder).to.exist
      callback = (err, data)->
        if err
          done(err)
          return
        folder2 = client.folderTree.get("/Bitcasa Infinite Drive/BitcasaF4JS")
        expect( folder2 ).to.exist
        done()
      folder.createFolder 'BitcasaF4JS', callback


    it 'should be able to upload files', (done) ->
      fs.writeFileSync('test.file',fileContent)
      callback = (err, args) ->
        fs.unlinkSync('test.file')
        if err
          console.log "error message from uploading", err
          done new Error(err.message)
        else
          file = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS/test.file")
          expect(file).to.exist
          folder = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS")
          expect(folder.children).to.contain("test.file")
          done()

      folder = client.folderTree.get('/Bitcasa Infinite Drive/BitcasaF4JS')
      folder.uploadFile './test.file', callback

    it 'should be able to download files properly', (done) ->
      file = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS/test.file")
      expect(file).to.exist
      cb = (buffer, start,end)->
        expect( buffer.toString() ).to.equal(fileContent)
        expect( end - start ).to.equal(fileContent.length)
        location = "#{config.cacheLocation}/download/#{file.bitcasaBasename}-0-#{file.size-1}"
        expect( fs.existsSync(location) ).to.be.true
        done()

      file.download(0, file.size-1, cb)

    it 'should be able to download files from cache as well', (done) ->
      file = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS/test.file")
      expect(file).to.exist
      cb = (buffer, start,end)->
        expect( buffer.toString() ).to.equal(fileContent)
        expect( end - start ).to.equal(fileContent.length)
        expect( fs.existsSync("#{config.cacheLocation}/download/#{file.bitcasaBasename}-0-#{fileContent.length-1}")).to.be.true
        done()

      file.download(0, file.size-1, cb)

    it 'should fail to delete a non empty directory', (done) ->
      callback = (err,args) ->
        if err
          done()
        else
          done(args)
      folder = client.folderTree.get('/Bitcasa Infinite Drive/BitcasaF4JS')
      folder.delete callback


    it 'should be able to delete files', (done) ->
      file = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS/test.file")
      expect(file).to.exist

      callback = (err, args) ->
        if err
          done(err)
        else
          expect( client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS/test.file") ).to.not.exist
          expect( fs.existsSync("#{config.downloadLocation}/#{file.bitcasaBasename}-0-#{fileContent.length-1}")).to.not.be.true
          folder = client.folderTree.get( "/Bitcasa Infinite Drive/BitcasaF4JS")
          expect(folder.children).to.not.contain("test.file")
          expect(folder.children.length).to.equal(0)

          done()

      file.delete(callback)

    it 'should fail to create directories greater than 64 bytes', (done) ->
      callback = (err, arg) ->
        if err
          expect(err.code).to.equal(2031)
          done()
        else
          done(arg)
      folder = client.folderTree.get('/Bitcasa Infinite Drive/BitcasaF4JS')
      folder.createFolder("long folder with more than 64 characthers - it is actually 65 now", callback)


    it 'should be able to delete empty directories', ->
      callback = (err,args) ->
        if err
          done(err)
        else
          done()
      folder = client.folderTree.get('/Bitcasa Infinite Drive/BitcasaF4JS')
      folder.delete callback
