module.exports = (grunt) ->

  # Project configuration.
  src_files = ['src/*.coffee']
  grunt.initConfig({
    pkg: grunt.file.readJSON('package.json'),
    coffee: {
      compile: {
        files: {
          # 'build/bitcasa/filesystem.js': ['src/file.coffee', 'src/folder.coffee'],
          'build/fs.js': ['src/file.coffee', 'src/folder.coffee', 'src/client.coffee', 'src/fs.coffee'],
          'build/watch.js': ['src/watch.coffee'],
          'build/downloader.js': ['src/downloader.coffee'],
          'build/ls.js': ['src/file.coffee', 'src/folder.coffee','src/ls.coffee']
        }
      }
    },
    coffee_jshint: {
      options: {
        #Task-specific options go here.
      },
      your_target: {
        src_files
      }
    },

    watch:{
      configFiles: {
        files: [ 'Gruntfile.coffee' ],
        options: {
          reload: true
        }
      },
      scripts:{
        files:['src/ls.coffee','src/downloader.coffee', 'src/file.coffee', 'src/folder.coffee', 'src/client.coffee', 'src/fs.coffee', 'test/**/*.coffee']
        tasks:['copy','coffee']
      }
    },
    mochaTest: {
      test: {
        options: {
          reporter: 'spec',
          clearRequireCache: true,
          timeout: 30000,
          require: ['coffee-script/register'],
        },
        src: ['test/testClient.coffee', 'test/testFS.coffee']
      }
    },
    copy:
      main:
        files: [{
          src: 'src/config.json.sample',
          dest: 'build/config.json.sample',
        },
        {
          src: 'src/start.sh',
          dest: 'build/start.sh.sample'
        }],
    ,

  });

  grunt.loadNpmTasks('grunt-contrib-coffee');
  grunt.loadNpmTasks('grunt-coffee-jshint');
  grunt.loadNpmTasks('grunt-contrib-watch');
  grunt.loadNpmTasks('grunt-mocha-test');
  grunt.loadNpmTasks('grunt-contrib-copy');

  # Default task(s).
  grunt.registerTask('default', ['copy', 'coffee']);
