module.exports = (grunt) ->

  # Project configuration.
  grunt.initConfig
    pkg: grunt.file.readJSON('package.json')
    watch:
      gruntfile:
        files: ['./Gruntfile.coffee']
        tasks: ['default']
      client:
        files: ['./client.coffee']
        tasks: ['coffee', 'uglify']
      stylesheets:
        files: ['style.less']
        tasks: ['less']
      livereload:
        files: ['public/*']
        options:
          livereload: true
    uglify:
      'public/app.js': [
        'node_modules/zepto/zepto.min.js'
        'node_modules/underscore/underscore.js'
        'node_modules/backbone/backbone.js'
        'node_modules/backbone.stickit/backbone.stickit.js'
        'node_modules/moment/moment.js'
        'public/dropzone.js'
        'public/client.js'
      ]
      options:
        mangle: false
        beautify: {
          width: 80,
          beautify: true
        }
    less:
      style:
        files:
          './public/style.css': './style.less'
    coffee:
      client:
        files:
          './public/client.js': './client.coffee'

  grunt.loadNpmTasks('grunt-contrib-watch')
  grunt.loadNpmTasks('grunt-contrib-coffee')
  grunt.loadNpmTasks('grunt-contrib-less')
  grunt.loadNpmTasks('grunt-contrib-uglify')
  
  # Default task(s).
  grunt.registerTask('default', ['less', 'coffee', 'uglify'])