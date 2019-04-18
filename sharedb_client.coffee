import ShareDB from 'sharedb/lib/client'
import ReconnectingWebSocket from 'reconnecting-websocket'
import RichText from 'rich-text'
import utils from '../../imports/utils.js'
import cursors from '../../imports/cursors.coffee'

ShareDB.types.register RichText.type
shareDBSocket = null
shareDBConnection = null

try
  shareDBSocket = new ReconnectingWebSocket(ReturnWebSocketURL('sharedb'))
  shareDBConnection = new ShareDB.Connection(shareDBSocket)
catch error
  console.log 'sharedb_client reconnecting socket error ', error

retryAttempts = 0
maxRetryAttempts = 2
openSocketTimeout = false
@ShareDBConnection = shareDBConnection
@ClearRefreshTimeout = ->
  retryAttempts = 0
# create and connect with a newly generated sharedb websocket
@StartNotepadRefreshTimeout = ->
  unless (ShareDBConnection.socket?.readyState is WebSocket.OPEN)
    if (ShareDBConnection.socket?.readyState is WebSocket.CONNECTING)
      ShareDBConnection.socket.close()
    Meteor.defer ->
      shareDBSocket = new ReconnectingWebSocket(ReturnWebSocketURL('sharedb'))
      ShareDBConnection.bindToSocket(shareDBSocket)
      ClearRefreshTimeout()
      scheduleOpenSocker(800)
      console.log 'creating new sharedb socket because cannot connect to sharedb', retryAttempts
# open the sharedb websocket
openSock = _.throttle ->
  if Meteor.status().connected is true
    if (ShareDBConnection.socket?.readyState is WebSocket.CLOSING) or (ShareDBConnection.socket?.readyState is WebSocket.CLOSED)
      if retryAttempts > maxRetryAttempts
        StartNotepadRefreshTimeout()
      else
        shareDBConnection.socket.reconnect()
        retryAttempts++
        console.log 'attempting to open sharedb socket, retry count ' + retryAttempts
    else if (ShareDBConnection.socket?.readyState is WebSocket.OPEN)
      ClearRefreshTimeout()
      ShareDBConnected.set true
    else if (ShareDBConnection.socket?.readyState is WebSocket.CONNECTING)
      if retryAttempts > maxRetryAttempts
        StartNotepadRefreshTimeout()
      else
        retryAttempts++
        console.log 'sharedb socket still connecting, waiting, retry count ' + retryAttempts
, 900
# set a timeout to call openSock()
scheduleOpenSocker = (delay) ->
  unless Session.get('online') and (Meteor.status().connected is true)
    return
  unless delay?
    delay = 4000
  if SessionIsIdle
    return
  if openSocketTimeout
    Meteor.clearTimeout openSocketTimeout
  openSocketTimeout = Meteor.setTimeout ->
    openSock()
  , delay

@ShareDBConnected = new ReactiveVar false
# sharedb connection event listeners
shareDBConnection.on 'error', (err) ->
  console.warn err, ' sharedb connection error'
  if ShareDBConnection.state is 'connected'
    ShareDBConnected.set true
  else
    scheduleOpenSocker(2100)
shareDBConnection.on 'connecting', ->
  console.log ' sharedb connecting'
shareDBConnection.on 'connected', (err) ->
  ShareDBConnected.set true
  ClearRefreshTimeout()
  console.log ' sharedb connected'
shareDBConnection.on 'disconnected', (err) ->
  # Connection is closed, but it will reconnect automatically
  ShareDBConnected.set false
  console.log ' sharedb disconnected'
shareDBConnection.on 'closed', (err) ->
  ShareDBConnected.set false
  console.log ' sharedb closed'
  scheduleOpenSocker(2100)
shareDBConnection.on 'stopped', (err) ->
  ShareDBConnected.set false
  console.log ' sharedb stopped'
  scheduleOpenSocker(2100)

# close sharedb socket if apps main websocket can't connect
Meteor.startup ->
  Meteor.setTimeout ->
    Tracker.autorun (c) ->
      if (Meteor.status().connected is false) and (Meteor.status().status isnt 'connecting')
        Meteor.defer ->
          if (shareDBSocket?.readyState is WebSocket.OPEN) or (shareDBSocket?.readyState is WebSocket.CONNECTING)
            console.log 'closing sharedb socket'
            try
              ShareDBConnection.socket.close(1000, 'app is offline')
            catch error
              console.warn 'error closing sharedb socket ', error
      else if Meteor.status().connected is true
        Meteor.defer ->
          if (shareDBSocket?.readyState is WebSocket.CLOSING) or (shareDBSocket?.readyState is WebSocket.CLOSED)
            console.log 'opening sharedb socket'
            try
              ShareDBConnection.socket.reconnect()
            catch error
              console.warn 'error opening sharedb socket ', error
      return Meteor.status().status
  , 5000
  return true

@CheckShareDBSocketOpen = ->
  openSock()
  if (ShareDBConnection.state is "connected") and (ShareDBConnected.get() is false)
    ShareDBConnected.set true
    ClearRefreshTimeout()
  return ((shareDBConnection.state is "connected") or (shareDBConnection.state is "connecting")) and shareDBConnection.canSend and shareDBConnection.id?

@DeRegisterCursorWithNotepad = (t, notepadId) ->
  if notepadId?
    cursors.removeMe(notepadId)
    Meteor.call 'endNotepadConnection', notepadId, cursors.localConnection.userId
  t.notepadConnSub?.stop()
  t.deRegisteringNotepad = true

# register a users cursor for the notepad they are viewing, used for multi-cursor collaboration
@RegisterCursorWithNotepad = (t, notepadId, publicNoteOrNotepad, noteId) ->
  return unless Session.get('online')
  return unless !!notepadId
  if Meteor.userId()
    color = GetUserColor(notepadId, Meteor.userId())
    name = MyName()
  else
    color = GetRandColor(5)
    name = 'user_' + Random.id(3)

  cursors.setCursor name, color, notepadId, noteId

  t.notepadConnSub = t.subscribe 'notepadConnections', notepadId

  t.createConnection = ->
    existingConnection = NotepadConnections.findOne({userId: (Meteor.userId() or cursors.localConnection.userId), notepadId: notepadId})
    unless !!existingConnection
      Meteor.call 'newNotepadConnection', notepadId, name, color, (Meteor.userId() or cursors.localConnection.userId)

  t.autorun (c) ->
    if t.notepadConnSub.ready() and Meteor.status().connected and (window.SessionIsIdleReactive?.get() is false)
      existingConnection = NotepadConnections.findOne({userId: (Meteor.userId() or cursors.localConnection.userId), notepadId: notepadId})
      unless !!existingConnection
        Meteor.setTimeout ->
          unless !!t.deRegisteringNotepad
            console.log 'calling create notepad connection'
            t.createConnection()
        , 800
    else if Meteor.status().connected is false
      existingConnection = NotepadConnections.findOne({userId: (Meteor.userId() or cursors.localConnection.userId), notepadId: notepadId})
      if !!existingConnection?._id
        NotepadConnections.remove existingConnection._id
    t.notepadConnSub.ready() and Meteor.status().connected and (window.SessionIsIdleReactive?.get() is false) and !!!existingConnection

  t.unloadNotepadFn = ->
    DeRegisterCursorWithNotepad(t, notepadId)
  $('body').one 'unloading', t.unloadNotepadFn

@DeleteShareDBNote = (t) ->
  return unless Session.get('online')
  t.pendingOperation = false
  t.deRegisteringNote = true
  if t.preventUnloadIfSaving?
    $(window).off 'beforeunload', t.preventUnloadIfSaving
  if t.sharedbDoc?
    t.sharedbDoc.destroy()
    t.sharedbDoc.del (err) ->
      if err
        console.log err
      else
        delete t.sharedbDoc

# cleanup when any particular note is no longer in view
@DeregisterQuillNote = (t) ->
  # this should only be registered on the quill note if online mode
  t.pendingOperation = false
  t.deRegisteringNote = true
  t.subscribeComp?.stop()
  if t.preventUnloadIfSaving?
    $(window).off 'beforeunload', t.preventUnloadIfSaving

  if t.clearCursors?
    $('body').off 'clearCursors', t.clearCursors

  if t.bulkDeleteNoteEventFn?
    $('.notepad-container').off 'delete-sharedb-note', t.bulkDeleteNoteEventFn

  if t.sharedbDoc?
    t.sharedbDoc.destroy()
    delete t.sharedbDoc

  # subscribing to cursor documents
  t.cursorsSub?.stop()
  # tracking changes for cursors docs for this note
  t.cursorsHandle?.stop()
  myCursor = Cursors.findOne
    noteId: t.data._id
    userId: cursors.localConnection.userId
  if myCursor?
    Meteor.call 'deleteCursorData', myCursor._id

# called for every note rendered on screen to register it with collaboration services
@RegisterQuillNote = (t, noteId) ->
  # this is registered for +quillNote components
  # and for +pNote component for public notes
  # every quill note needs to be registered except scratchpad and quick note
  noteDoc = Notes.findOne(noteId) or ESSearchResults.findOne(noteId)
  quill = t.editor

  unless noteDoc?._id?
    if t.data._id? and t.data.notepadId?
      console.warn 'could not find notes doc in collection using t.data', t.data
      noteDoc = t.data
    else
      console.warn 'could not find note document', t.data
      return

  if IsNoteOrNotepadEncrypted(noteDoc)
    # if note or notepad is encrypted then I want to register the update content autorun
    # and do not use ShareDB with encrypted notes, so returning
    UpdateQuillNoteAutorun(t)
    CollabEditingAutorun(t)
    t.addCurrentlyEditingAutorun?()
    return

  return false unless Session.get('online')

  # past this point you have to be online for everything to work
  # and nothing past should be needed when offline
  unless !!shareDBConnection
    console.warn 'shareDBConnection is not defined returning', shareDBConnection
    return

  openSock()

  unless !!ShareDBConnection?.id
    console.warn 'no sharedb connection ID'
    t.sharedbConnectComp?.stop()
    Meteor.setTimeout ->
      t.sharedbConnectComp = t.autorun (c) ->
        if ShareDBConnected.get()
          c.stop()
          unless !!t.deRegisteringNote
            console.log 'trying to register quill note again'
            RegisterQuillNote t, noteId
        return ShareDBConnected.get()
    , 100
    return

  t.bulkDeleteNoteEventFn = (e, noteDocID) ->
    if noteDocID is noteId
      DeleteShareDBNote(t)

  $('.notepad-container').on 'delete-sharedb-note', t.bulkDeleteNoteEventFn

  Meteor.setTimeout ->
    if noteDoc?._id? and !!!t.deRegisteringNote
      t.cursorsSub = t.subscribe 'cursors', noteDoc._id
  , 1

  cursorsModule = quill.getModule 'cursors'

  t.clearCursors = (e) ->
    cursorsModule.clearCursors()

  $('body').on 'clearCursors', t.clearCursors

  t.unloadFn = ->
    t.unloadingEventCalled = true
    DeregisterQuillNote(t)
  $('body').one 'unloading', t.unloadFn

  setSocketThenSubscribe = (err) ->
    if err
      meteorCallSetSocket()
      console.warn err
      return

    if t.subscribedShareDB?.get()
      console.warn 'already subscribed to sharedb document'
      return

    unless noteDoc?._id?
      console.log 'removed note before getting sharedb doc'
      return

    doc = shareDBConnection.get 'sharedb_notes', noteDoc._id
    t.sharedbDoc = doc
    doc.subscribe (err) ->
      if err
        meteorCallSetSocket()
        console.warn err
        return
      t.subscribedShareDB?.set true
      t.pendingOperation = false
      sendOpTimeoutMS = 1
      receiveOpTimeoutMS = 10
      sendCursorData = _.throttle (range) ->
        return if !!!cursors.localConnection
        cursors.localConnection.range = range
        cursors.update(noteId)
        return
      , (receiveOpTimeoutMS - 1),
        leading: false

      t.cursorsMap = {}
      setCursor = (id) ->
        data = t.cursorsMap[id]
        if data.userId isnt cursors.localConnection.userId
          Meteor.setTimeout ->
            cursorsModule.setCursor data.userId, data.range, data.name, data.color
          , 0

      unless noteDoc?._id?
        return
      noteCursors = Cursors.find({noteId: noteDoc._id})
      t.cursorsHandle = noteCursors.observeChanges
        changed: (id, fields) ->
          _.each Object.keys(fields), (key) ->
            t.cursorsMap[id][key] = fields[key]
          data = t.cursorsMap[id]
          if !!fields.blurMe
            cursorsModule.hideCursor data.userId
          else if data.range? and data.range isnt null
            setCursor(id)
          else
            cursorsModule.hideCursor data.userId
        added: (id, fields) ->
          t.cursorsMap[id] = fields
          setCursor(id)
        removed: (id) ->
          if t.cursorsMap[id]?.userId
            cursorsModule.removeCursor t.cursorsMap[id].userId
            delete t.cursorsMap[id]

      # this subscriptionReady ReactiveVar is added to
      # notepad instance t from pagination pages setup
      # In fullscreen note modal, subscriptionReady is
      # the return value from subscribing to the note
      subHandler = t.parentTemplate().subscriptionReady
      createDocIfDoesntExist = (onlyCreateNoSet) =>
        if !!t.deRegisteringNote or !!t.unloadingEventCalled or !Session.get('online')
          return false
        t.autorun (c) ->
          unless Session.get('online')
            c.stop()
            return
          if !!t.data.fullscreenNote
            subIsReady = subHandler.ready()
          else if !!t.data.publicNote
            subIsReady = Router.current().ready()
          else
            subIsReady = subHandler.get()
          if subIsReady and not IsCurrentlySyncing.get()
            c.stop()
            noteDocNotes = Notes.findOne noteId
            noteDocSearch = ESSearchResults.findOne noteId
            noteDoc = noteDocNotes or noteDocSearch
            if noteDoc?.quillDelta?
              quillDelta = ReturnDecryptedItem(noteDoc, 'quillDelta')
            if !doc.type
              t.pendingOperation = true
              if quillDelta?.ops?
                try
                  doc.create quillDelta, 'rich-text'
                catch error
                  console.log error
                  t.pendingOperation = false
              else
                try
                  doc.create [], 'rich-text'
                catch error
                  console.log error
                  t.pendingOperation = false

            unless !!onlyCreateNoSet
              unless !!t.updated or t.editor?.hasFocus()
                if doc.data?.ops?
                  quill.setContents doc.data, 'silent'
                else if quillDelta?.ops?
                  quill.setContents quillDelta, 'silent'

          # this tracker function is watching for the sub to be ready 
          # and also waits until initial offline to online sync is complete
          !!subIsReady and IsCurrentlySyncing.get()

      createDocIfDoesntExist()
      cursorsModule.registerTextChangeListener()
      t.$('.ql-editor').on 'blur', (e) ->
        cursors.removeMe(Session.get('notepadId'), noteId)

      # local -> server
      combineOpArray = (opsArray) ->
        if opsArray.length > 0
          newOp = opsArray.shift()
          combineOps = _.clone opsArray
          if combineOps.length > 0
            addOp = null
            newOpDelta = RichText.type.deserialize newOp.ops
            _.each combineOps, (op) ->
              if addOp?.ops?
                newOpDelta = RichText.type.deserialize _.clone(addOp.ops)
              addOp = newOpDelta.compose op
            opsArray.splice(0, combineOps.length)
            combineOps  = []
            return addOp
          else
            return newOp
        else
          console.warn 'combine ops array is empty'
          return (new Delta())

      sendOpQueue = []
      sendingOp = false
      allowNewData = true
      # is the user allowed new data based on their current subscription plan
      # new data is always allowed for public notepads and notes
      checkAllowNewData = _.throttle ->
        isPublic = (Router.current().route.getName() is 'publicNotepad') or (Router.current().route.getName() is 'publicNote')
        if isPublic
          allowNewData = true
        else
          userId = t.data?.userId or noteDoc?.userId or Meteor.userId()
          allowNewData = IsAllowedNewData(userId)
        unless allowNewData
          console.log 'new data not allowed, disk limits, sharedb op not sent'
      , 20000
      sendOp = (delta) ->
        unless ShareDBConnected.get()
          console.log 'cannot send op, sharedb is not connected'
          return
        checkAllowNewData()
        unless allowNewData
          return
        sendingOp = true
        Meteor.setTimeout ->
          doc.submitOp delta, { source: quill }, (err) ->
            if err
              console.warn 'Submit OP returned an error:', err
            else
              if sendOpQueue.length > 0
                newDelta = combineOpArray sendOpQueue
                sendOp(newDelta)
              else
                sendingOp = false
        , sendOpTimeoutMS

      # watches the editor for text changes, and is called for every changes with the deltas
      quill.on 'text-change', (delta, oldDelta, source) ->
        return if t.$('.quill-editor').hasClass('ql-disabled')
        return unless Session.get('online')
        if source is 'user'
          unless CheckShareDBSocketOpen()
            console.warn t?.sharedbDoc, ' the sharedb doc, sharedb socket not open while submitting op'
            return
          if !!!t?.sharedbDoc?.type
            console.warn 'doc doesnt exist while trying to submit op', t?.sharedbDoc
            createDocIfDoesntExist(true)
          if cursors.localConnection.range and cursors.localConnection.range.length
            cursors.localConnection.range.index += cursors.localConnection.range.length
            cursors.localConnection.range.length = 0
            cursors.update(noteId)
          t.pendingOperation = true
          # if the previously sent op is still pending, add future changes to an op queue
          if sendingOp
            console.log 'pushing sending op into queue'
            sendOpQueue.push delta
          else
            sendOp delta

      # server -> local
      applyOpQueue = []
      applyingOp = false
      applyOp = (op) ->
        applyingOp = true
        Meteor.setTimeout ->
          quill.updateContents op, 'api'
          if applyOpQueue.length > 0
            newDelta = combineOpArray applyOpQueue
            applyOp newDelta
          else
            applyingOp = false
        , receiveOpTimeoutMS
      doc.on 'op', (op, source) ->
        if source isnt quill
          # if incoming stream of ops are too fast can lead to issues
          # slowing down applying operations to the document helps by using a queue
          if applyingOp
            console.log 'pushing recieve op into queue'
            applyOpQueue.push op
          else
            applyOp op

      _sendCursorData = ->
        range = quill.getSelection()
        if range
          sendCursorData range
      debouncedSendCursorData = _.debounce _sendCursorData, 50
      debouncedSendCursorData2 = _.debounce _sendCursorData, 1500
      whenNothingPendingFn = ->
        t.pendingOperation = false
        debouncedSendCursorData()
        debouncedSendCursorData2()

      doc.on 'nothing pending', whenNothingPendingFn
      doc.on 'del', (data, source) ->
        console.log 'this document was deleted', data, source
      doc.on 'error', (err) ->
        t.pendingOperation = false
        switch err.code
          when 4015, 4017
            createDocIfDoesntExist()

      quill.on 'selection-change', (range, oldRange, source) ->
        if quill.hasFocus()
          sendCursorData range

      t.preventUnloadIfSaving = (e) ->
        return unless Session.get('online')
        if !!t.pendingOperation
          if Meteor.isDesktop
            swal('Your changes are currently being saved', 'Please wait a few seconds until saving is complete before closing', 'warning')
            return false
          else
            return 'Your changes are currently being saved. Are you sure you want to quit?'

      $(window).on 'beforeunload', t.preventUnloadIfSaving

      # the UpdateQuillHistoryStackAutorun should be initialized after initial set contents
      # history operation specigfic too each user is synced between all their devices
      # initializing the tracker below does this
      UpdateQuillHistoryStackAutorun(t)

  # this only registers the note with collaboration services if ShareDB Connection can be made
  meteorCallSetSocket = _.throttle ->
    if !!t.callingShareSub
      return
    t.callingShareSub = true
    Meteor.defer ->
      t.subscribeComp = t.autorun (c) ->
        if !!t.deRegisteringNote
          c.stop()
          t.callingShareSub = false
          return
        else if ShareDBConnected.get()
          c.stop()
          t.callingShareSub = false
          setSocketThenSubscribe()
        else
          console.log 'cannot connect to Memrey collaboration services...'
        return ShareDBConnected.get()
  , 400

  t.subscribeComp?.stop()
  meteorCallSetSocket()

  # this is backup autorun to update your note in case
  # sharedb ops dont update it while away
  # this is only used for non encrypted notes

  # backup autorun is not neccessarily needed anymore since I prevent the user from editing the note when sharedb connection is not active
  
  # t.lastRecordedContentUpdate = false
  # attachBackupContentUpdateAutorun = ->
  #   # sharedb to connect if loading app on notepad
  #   Meteor.defer ->
  #     t.backupContentUpdateAutorun = t.autorun ->
  #       # update contents silently if sharedb connection is closed
  #       noteDoc = Notes.findOne({_id: t.data._id}, {fields: {quillDelta: 1, contentUpdatedAt: 1}}) or ESSearchResults.findOne({_id: t.data._id}, {fields: {quillDelta: 1, contentUpdatedAt: 1}})

  #       if noteDoc?.quillDelta?
  #         if t.lastRecordedContentUpdate and moment(noteDoc.contentUpdatedAt).isAfter(t.lastRecordedContentUpdate) and !CheckShareDBSocketOpen() and !!!t.subscribedShareDB?.get()
  #           console.warn 'silently updating quill note contents because sharedb isnt connected'
  #           t.editor.setContents noteDoc.quillDelta, 'silent'

  #       t.lastRecordedContentUpdate = noteDoc?.contentUpdatedAt

  #       return noteDoc?.contentUpdatedAt
  # Meteor.defer ->
  #   t.backupContentUpdateAutorun?.stop()
  #   attachBackupContentUpdateAutorun()

@CursorsSync = cursors
