chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
config = require '../build/test.config.json'
fs = require 'fs-extra'
sys = require 'sys'
exec = require('child_process').exec;

describe 'FUSE filesystem', ->

  it 'should be mountable', (done)->
    require '../src/fs.coffee'
    setTimeout done, 5000

  it 'should list the infinite drive', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
        return
      expect(stdout).to.contain("Bitcasa Infinite Drive")
      done()
    exec("ls #{config.mountPoint}", callback )

  it 'should be able to create a directory', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
        return
      console.log stdout
      console.log stderr
      callback2 = (err,stdout, stderr)->
        if err
          done("There was an error #{err}")
          return

        expect(stdout).to.contain("BitcasaF4JS")
        done()
      exec("ls \"#{config.mountPoint}/Bitcasa Infinite Drive\"", callback2 )
    exec "mkdir \"#{config.mountPoint}/Bitcasa Infinite Drive/BitcasaF4JS\"", callback
  it 'should not be able to create a directory that already exist', (done) ->
    callback = (err,stdout, stderr)->
      if err
        done()
      else
        done("there was no error")
    exec "mkdir \"#{config.mountPoint}/Bitcasa Infinite Drive/BitcasaF4JS\"", callback

  it 'should not be able to create a directory with more than 64 chars', (done) ->
    callback = (err,stdout, stderr) ->
      if err
        done()
      else
        done("there was no error")
    exec "mkdir \"#{config.mountPoint}/Bitcasa Infinite Drive/BitcasaF4JS super long char long long long long long long long long long long long long long long long\"", callback

  it 'should be able to create a file'
  it 'should not be able to remove a non-empty folder'
  it 'should be able to delete a file'
  it 'should be able to move directories'
  it 'should be able to move files'
  it 'should be able to copy files'

  it 'should be able to delete an empty folder', (done) ->
    callback3 = (err,stdout, stderr)->
      if err
        done("There was an error #{err}")
        return
      expect(stdout).to.contain("BitcasaF4JS")

      callback = (err,stdout, stderr)->
        if err
          console.log err
          done("There was an error #{err}")
          return
        callback2 = (err,stdout, stderr)->
          if err
            console.log err
            done("There was an error #{err}")
            return

          expect(stdout).to.not.contain("BitcasaF4JS")
          done()
        exec("ls \"#{config.mountPoint}/Bitcasa Infinite Drive\"", callback2 )
      exec "rmdir \"#{config.mountPoint}/Bitcasa Infinite Drive/BitcasaF4JS\"", callback

    exec("ls \"#{config.mountPoint}/Bitcasa Infinite Drive\"", callback3 )



  it 'should be unmountable', (done) ->
    callback = (err,stdout, stderr)->
      if err
        console.log err
        done("There was an error #{err}")
      expect(stdout).to.equal("Unmount successful for #{config.mountPoint}\n")
      done()
    fn = ->
      exec("diskutil unmount force #{config.mountPoint}", callback )

    setTimeout(fn, 2000)
