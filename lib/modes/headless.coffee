_          = require("lodash")
fs         = require("fs-extra")
uuid       = require("uuid")
path       = require("path")
chalk      = require("chalk")
human      = require("human-interval")
Promise    = require("bluebird")
inquirer   = require("inquirer")
random     = require("randomstring")
ss         = require("../screenshots")
user       = require("../user")
stats      = require("../stats")
video      = require("../video")
errors     = require("../errors")
Project    = require("../project")
Reporter   = require("../reporter")
browsers   = require("../browsers")
openProject = require("../open_project")
progress   = require("../util/progress_bar")
trash      = require("../util/trash")
terminal   = require("../util/terminal")
humanTime  = require("../util/human_time")
Windows    = require("../gui/windows")
pkg        = require("../../package.json")

fs = Promise.promisifyAll(fs)

TITLE_SEPARATOR = " /// "

haveProjectIdAndKeyButNoRecordOption = (projectId, options) ->
  ## if we have a project id
  ## and we have a key
  ## and (record or ci) hasn't been set to true or false
  (projectId and options.key) and (_.isUndefined(options.record) and _.isUndefined(options.ci))

module.exports = {
  getId: ->
    ## return a random id
    random.generate({
      length: 5
      capitalization: "lowercase"
    })

  getProjectId: (project, id) ->
    ## if we have an ID just use it
    if id
      return Promise.resolve(id)

    project
    .getProjectId()
    .catch ->
      ## no id no problem
      return null

  ensureAndOpenProjectByPath: (id, options) ->
    ## verify we have a project at this path
    ## and if not prompt the user to add this
    ## project. once added then open it.
    {projectPath} = options

    open = =>
      @openProject(id, options)

    Project.exists(projectPath)
    .then (bool) =>
      ## if we have this project then lets
      ## immediately open it!
      return open() if bool

      ## else tell the user we're adding this project
      console.log(
        "Added this project:"
        chalk.cyan(projectPath)
      )

      Project.add(projectPath)
      .then(open)

  openProject: (id, options) ->
    ## now open the project to boot the server
    ## putting our web client app in headless mode
    ## - NO  display server logs (via morgan)
    ## - YES display reporter results (via mocha reporter)
    openProject.create(options.projectPath, options, {
      morgan:       false
      socketId:     id
      report:       true
      isHeadless:   options.isHeadless ? true
    })
    .catch {portInUse: true}, (err) ->
      ## TODO: this needs to move to emit exitEarly
      ## so we record the failure in CI
      errors.throw("PORT_IN_USE_LONG", err.port)

  createRecording: (name) ->
    outputDir = path.dirname(name)

    fs.ensureDirAsync(outputDir)
    .then ->
      console.log("\nStarted video recording: #{chalk.cyan(name)}\n")

      video.start(name, {
        onError: (err) ->
          ## catch video recording failures and log them out
          ## but don't let this affect the run at all
          errors.warning("VIDEO_RECORDING_FAILED", err.stack)
      })

  getElectronProps: (showGui, project, write) ->
    obj = {
      width:             1280
      height:            720
      show:              showGui
      devTools:          showGui
      onCrashed: ->
        err = errors.get("RENDERER_CRASHED")
        errors.log(err)

        project.emit("exitEarlyWithErr", err.message)
      onNewWindow: (e, url, frameName, disposition, options) ->
        ## force new windows to automatically open with show: false
        ## this prevents window.open inside of javascript client code
        ## to cause a new BrowserWindow instance to open
        ## https://github.com/cypress-io/cypress/issues/123
        options.show = false
    }

    if write
      obj.recordFrameRate = 20
      obj.onPaint = (event, dirty, image) ->
        write(image.toJPEG(100))

    obj

  displayStats: (obj = {}) ->
    bgColor = if obj.failures then "bgRed" else "bgGreen"
    color   = if obj.failures then "red"   else "green"

    console.log("")

    terminal.header("Tests Finished", {
      color: [color]
    })

    console.log("")

    stats.display(color, {
      tests:       obj.tests
      passes:      obj.passes
      pending:     obj.pending
      failures:    obj.failures
      duration:    humanTime(obj.duration)
      screenshots: obj.screenshots and obj.screenshots.length
      video:       !!obj.video
      version:     pkg.version
    })

  displayScreenshots: (screenshots = []) ->
    console.log("")
    console.log("")

    terminal.header("Screenshots", {color: ["yellow"]})

    console.log("")

    format = (s) ->
      dimensions = chalk.gray("(#{s.width}x#{s.height})")

      "  - #{s.path} #{dimensions}"

    screenshots.forEach (screenshot) ->
      console.log(format(screenshot))

  postProcessRecording: (end, name, cname, videoCompression) ->
    ## once this ended promises resolves
    ## then begin processing the file
    end()
    .then ->
      ## dont process anything if videoCompress is off
      return if videoCompression is false

      console.log("")
      console.log("")

      terminal.header("Video", {
        color: ["cyan"]
      })

      console.log("")

      # bar = progress.create("Post Processing Video")
      console.log("  - Started processing:  ", chalk.cyan("Compressing to #{videoCompression} CRF"))

      started  = new Date
      progress = Date.now()
      tenSecs = human("10 seconds")

      onProgress = (float) ->
        switch
          when float is 1
            finished = new Date - started
            duration = "(#{humanTime(finished)})"
            console.log("  - Finished processing: ", chalk.cyan(name), chalk.gray(duration))

          when (new Date - progress) > tenSecs
            ## bump up the progress so we dont
            ## continuously get notifications
            progress += tenSecs
            percentage = Math.ceil(float * 100) + "%"
            console.log("  - Compression progress: ", chalk.cyan(percentage))

        # bar.tickTotal(float)

      video.process(name, cname, videoCompression, onProgress)
    .catch {recordingVideoFailed: true}, (err) ->
      ## dont do anything if this error occured because
      ## recording the video had already failed
      return
    .catch (err) ->
      ## log that post processing was attempted
      ## but failed and dont let this change the run exit code
      errors.warning("VIDEO_POST_PROCESSING_FAILED", err.stack)

  waitForBrowserToConnect: (options = {}) ->
    { project, id, browser, gui, spec, write, timeout, screenshots } = options

    gui = !!gui

    browser ?= "electron"

    browserOpts = switch browser
      when "electron"
        @getElectronProps(gui, project, write)
      else
        {}

    browserOpts.automationMiddleware = {
      onAfterResponse: (message, data, resp) =>
        if message is "take:screenshot"
          screenshots.push @screenshotMetadata(data, resp)

        resp
    }

    launchBrowser = =>
      openProject.launch(browser, spec, browserOpts)

    attempts = 0

    do waitForBrowserToConnect = =>
      Promise.join(
        @waitForSocketConnection(project, id)
        launchBrowser()
      )
      .timeout(timeout ? 10000)
      .catch Promise.TimeoutError, (err) =>
        attempts += 1

        console.log("")

        ## always first close the open browsers
        ## before retrying or dieing
        openProject.closeBrowser()
        .then ->
          switch attempts
            ## try again up to 3 attempts
            when 1, 2
              word = if attempts is 1 then "Retrying..." else "Retrying again..."
              errors.warning("TESTS_DID_NOT_START_RETRYING", word)

              waitForBrowserToConnect()

            else
              err = errors.get("TESTS_DID_NOT_START_FAILED")
              errors.log(err)

              project.emit("exitEarlyWithErr", err.message)

  waitForSocketConnection: (project, id) ->
    new Promise (resolve, reject) ->
      fn = (socketId) ->
        if socketId is id
          ## remove the event listener if we've connected
          project.removeListener "socket:connected", fn

          ## resolve the promise
          resolve()

      ## when a socket connects verify this
      ## is the one that matches our id!
      project.on "socket:connected", fn

  waitForTestsToFinishRunning: (options = {}) ->
    { project, gui, screenshots, started, end, name, cname, videoCompression } = options

    new Promise (resolve, reject) =>
      ## dont ever end if we're in 'gui' debugging mode
      return if gui

      onFinish = (obj) =>
        finish = ->
          project
          .getConfig()
          .then (cfg) ->
            obj.config = cfg
          .finally ->
            resolve(obj)

        if end
          obj.video = name

        if screenshots
          obj.screenshots = screenshots

        @displayStats(obj)

        if screenshots and screenshots.length
          @displayScreenshots(screenshots)

        ft = obj.failingTests

        if ft and ft.length
          obj.failingTests = Reporter.setVideoTimestamp(started, ft)

        if end
          @postProcessRecording(end, name, cname, videoCompression)
          .then(finish)
          ## TODO: add a catch here
        else
          finish()

      onEarlyExit = (errMsg) ->
        ## probably should say we ended
        ## early too: (Ended Early: true)
        ## in the stats
        obj = {
          error:        errors.stripAnsi(errMsg)
          failures:     1
          tests:        0
          passes:       0
          pending:      0
          duration:     0
          failingTests: []
        }

        onFinish(obj)

      onEnd = (obj) =>
        onFinish(obj)

      ## when our project fires its end event
      ## resolve the promise
      project.once("end", onEnd)
      project.once("exitEarlyWithErr", onEarlyExit)

  trashAssets: (options = {}) ->
    if options.trashAssetsBeforeHeadlessRuns is true
      Promise.join(
        trash.folder(options.videosFolder)
        trash.folder(options.screenshotsFolder)
      )
      .catch (err) ->
        ## dont make trashing assets fail the build
        errors.warning("CANNOT_TRASH_ASSETS", err.stack)
    else
      Promise.resolve()

  screenshotMetadata: (data, resp) ->
    {
      clientId:  uuid.v4()
      title:      data.name ## TODO: rename this property
      # name:      data.name
      testId:    data.testId
      testTitle: data.titles.join(TITLE_SEPARATOR)
      path:      resp.path
      height:    resp.height
      width:     resp.width
    }

  copy: (videosFolder, screenshotsFolder) ->
    Promise.try ->
      ## dont attempt to copy if we're running in circle and we've turned off copying artifacts
      if (ca = process.env.CIRCLE_ARTIFACTS) and process.env["COPY_CIRCLE_ARTIFACTS"] isnt "false"
        Promise.join(
          ss.copy(screenshotsFolder, ca)
          video.copy(videosFolder, ca)
        )

  allDone: ->
    console.log("")
    console.log("")

    terminal.header("All Done", {
      color: ["gray"]
    })

    console.log("")

  runTests: (options = {}) ->
    { browser, videoRecording, videosFolder } = options

    screenshots = []

    ## we know we're done running headlessly
    ## when the renderer has connected and
    ## finishes running all of the tests.
    ## we're using an event emitter interface
    ## to gracefully handle this in promise land

    ## if we've been told to record and we're not spawning a headed browser
    if videoRecording and not browser
      id2       = @getId()
      name      = path.join(videosFolder, id2 + ".mp4")
      cname     = path.join(videosFolder, id2 + "-compressed.mp4")

      recording = @createRecording(name)

    Promise.resolve(recording)
    .then (props = {}) =>
      ## extract the started + ended promises from recording
      {start, end, write} = props

      terminal.header("Tests Starting", {color: ["gray"]})

      ## make sure we start the recording first
      ## before doing anything
      Promise.resolve(start)
      .then (started) =>
        Promise.props({
          stats:      @waitForTestsToFinishRunning({
            gui:              options.gui
            project:          options.project
            videoCompression: options.videoCompression
            end
            name
            cname
            started
            screenshots
          }),

          connection: @waitForBrowserToConnect({
            id:          options.id
            gui:         options.gui
            spec:        options.spec
            project:     options.project
            webSecurity: options.webSecurity
            write
            browser
            screenshots
          })
        })

  ready: (options = {}) ->
    id = @getId()

    ## verify this is an added project
    ## and then open it, returning our
    ## project instance
    @ensureAndOpenProjectByPath(id, options)
    .call("getProject")
    .then (project) =>
      Promise.all([
        @getProjectId(project, options.projectId)

        project.getConfig(),
      ])
      .spread (projectId, config) =>
        ## if we have a project id and a key but record hasnt
        ## been set
        if haveProjectIdAndKeyButNoRecordOption(projectId, options)
          ## log a warning telling the user
          ## that they either need to provide us
          ## with a RECORD_KEY or turn off
          ## record mode
          errors.warning("PROJECT_ID_AND_KEY_BUT_MISSING_RECORD_OPTION", projectId)

        ## old version of the CLI tools
        if not options.cliVersion
          errors.warning("OLD_VERSION_OF_CLI")

        @trashAssets(config)
        .then =>
          @runTests({
            id:               id
            project:          project
            videosFolder:     config.videosFolder
            videoRecording:   config.videoRecording
            videoCompression: config.videoCompression
            spec:             options.spec
            gui:              options.showHeadlessGui
            browser:          options.browser
          })
        .get("stats")
        .finally =>
          @copy(config.videosFolder, config.screenshotsFolder)
          .then =>
            if options.allDone isnt false
              @allDone()

  run: (options) ->
    app = require("electron").app

    waitForReady = ->
      new Promise (resolve, reject) ->
        app.on "ready", resolve

    Promise.any([
      waitForReady()
      Promise.delay(500)
    ])
    .then =>
      @ready(options)

}
