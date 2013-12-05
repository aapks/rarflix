'*
'* A simple wrapper around a slideshow. Single items and lists are both supported.
'*

Function createPhotoPlayerScreen(context, contextIndex, viewController)
    obj = CreateObject("roAssociativeArray")
    obj.OnTimerExpired = photoPlayerOnTimerExpired

    initBaseScreen(obj, viewController)
    GetGlobalAA().AddReplace("slideshow_overlay", false)

    screen = CreateObject("roSlideShow")
    screen.SetMessagePort(obj.Port)

    screen.SetUnderscan(2.5)
    screen.SetMaxUpscale(8.0)
    displayMode = RegRead("slideshow_displaymode", "preferences", "scale-to-fit")
    screen.SetDisplayMode(displayMode)
    screen.SetPeriod(RegRead("slideshow_period", "preferences", "6").toInt())
    screen.SetTextOverlayHoldTime(RegRead("slideshow_overlay", "preferences", "2500").toInt())

    ' ljunkie - we need to iterate through the items and remove directories -- they don't play nice
    ' note: if we remove directories ( itms ) the contextIndex will be wrong - so fix it!
    if type(context) = "roArray" then
        key = context[contextIndex].key
        print "---------------------wanted key" + key
        newcontext = []
        for each item in context
            if tostr(item.nodename) = "Photo" then 
                newcontext.Push(item)
            else 
                print "skipping item: " + tostr(item.nodename) + " " + tostr(item.title)
            end if
        next
        
        ' update the overlay on the upper right with (# of #)
        size = newcontext.count()-1
        for index = 0 to size
            newcontext[index].TextOverlayUR = tostr(index+1) + " of " + tostr(size)
        end for

        ' reset contextIndex if needed
        if context.count() <> newcontext.count() then 
            contextIndex = 0 ' reset context to zero, unless we find a match
            for index = 0 to newcontext.count() - 1 
                if key = newcontext[index].key then 
                    print "---------------------found key" + newcontext[index].key
                    contextIndex = index
                    exit for
                end if
            end for
        end if

        context = newcontext
    end if
    ' end cleaning

    ' Standard screen properties
    obj.Screen = screen
    obj.doReload = RegRead("slideshow_reload", "preferences", "disabled")
    if type(context) = "roArray" then
        obj.Item = context[contextIndex]
        obj.Items = context ' ljunkie - set items for access later
        AddAccountHeaders(screen, obj.Item.server.AccessToken)
        screen.SetContentList(context)
        screen.SetNext(contextIndex, true)
        Debug("PhotoPlayer total items: " + tostr(context.count()))
    else
        obj.Item = context
        AddAccountHeaders(screen, obj.Item.server.AccessToken)
        screen.AddContent(context)
        screen.SetNext(0, true)
    end if

    obj.IsPaused = false
    obj.ForceResume = false
    m.ViewController.AudioPlayer.focusedbutton = 0

    obj.HandleMessage = photoPlayerHandleMessage

    obj.playbackTimer = createTimer()

    return obj
End Function

Function photoPlayerHandleMessage(msg) As Boolean
    ' We don't actually need to do much of anything, the slideshow pretty much
    ' runs itself.

    handled = false

    if type(msg) = "roSlideShowEvent" then
        handled = true

        ' ljunkie - check if we have new context. Only set if slideshow_reload is enabled
        if m.doReload = "enabled" and m.newContext <> invalid and m.newContext.count() > 0 then 
            Debug("---- reloading slideshow with new context " + tostr(m.newContext.count()) + " items")
            m.screen.SetContentList(m.newContext)
            m.items = m.newContext
            m.newContext = invalid
        end if

        if msg.isScreenClosed() then
            ' Send an analytics event
            GetGlobalAA().AddReplace("slideshow_overlay", false)
            amountPlayed = m.playbackTimer.GetElapsedSeconds()
            Debug("Sending analytics event, appear to have watched slideshow for " + tostr(amountPlayed) + " seconds")
            m.ViewController.Analytics.TrackEvent("Playback", firstOf(m.Item.ContentType, "photo"), m.Item.mediaContainerIdentifier, amountPlayed)
            m.ViewController.PopScreen(m)
        else if msg.isPlaybackPosition() then
            m.CurIndex = msg.GetIndex() ' update current index
            ' ljunkie - check for new images after slideshow completeion ( if slideshow_reload is enabled )
	    if m.doReload = "enabled" and type(m.items) = "roArray" and m.CurIndex = m.items.count()-1 then 
                if m.item <> invalid and m.item.server <> invalid and m.item.sourceurl <> invalid then 
                    obj = createPlexContainerForUrl(m.item.server, m.item.sourceurl, "")
                    ' verify the new context <> current - save some load time
                    if obj.count() > 0 and obj.count() <> m.items.count() then m.newContext = obj.getmetadata()
                end if
            end if
        else if msg.isRequestFailed() then
            Debug("preload failed: " + tostr(msg.GetIndex()))
        else if msg.isRequestInterrupted() then
            Debug("preload interrupted: " + tostr(msg.GetIndex()))
        else if msg.isPaused() then
            audioplayer = GetViewController().AudioPlayer
            Debug("paused")
            m.isPaused = true
            if audioplayer.IsPlaying then audioplayer.Pause()
        else if msg.isResumed() then
            audioplayer = GetViewController().AudioPlayer
            Debug("resumed")
            m.isPaused = false
            if audioplayer.IsPaused then audioplayer.Resume()
        else if msg.isRemoteKeyPressed() then
            if ((msg.isRemoteKeyPressed() AND msg.GetIndex() = 10) OR msg.isButtonInfo()) then ' ljunkie - use * for more options on focused item
                obj = m.item     
                if type(m.items) = "roArray" and m.CurIndex <> invalid then obj = m.items[m.CurIndex]
                m.forceResume = NOT (m.isPaused)
                m.screen.Pause()
                m.isPaused = true
                photoPlayerShowContextMenu(obj)
            else if msg.GetIndex() = 3 then

                if GetGlobalAA().Lookup("slideshow_overlay") = false then
                    time = 2500 ' force show overlay (default to 2500 msec)
                    ' if EU has set pref as showing slideshow by default, set time to 0 ( to reverse logic - hide ol )
                    if RegRead("slideshow_overlay", "preferences", "2500").toInt() > 0 then time = 0
                    GetGlobalAA().AddReplace("slideshow_overlay", true)
                else
                    GetGlobalAA().AddReplace("slideshow_overlay", false)
                    ' we can now used the stored pref to either hide or show the overlay
                    time = RegRead("slideshow_overlay", "preferences", "2500").toInt()
                end if

                if time = 0 then
                    ' hide overlay
                    if m.overlayTimer <> invalid then m.overlayTimer.Active = false
                    m.screen.SetTextOverlayHoldTime(0)
                    ' Roku bug or feature? hae to set the overlay to true befre we can set it to false
                    m.screen.SetTextOverlayIsVisible(true)
                    m.screen.SetTextOverlayIsVisible(false)
                else 
                    ' show overlay
                    m.screen.SetTextOverlayHoldTime(2500)
                    m.screen.SetTextOverlayIsVisible(true)
                    ' using a timer will be less obtrusive. 
                    if m.overlayTimer = invalid then
                        m.overlayTimer = createTimer()
                        m.overlayTimer.Name = "overlay"
                        m.overlayTimer.Time = time
                        m.overlayTimer.SetDuration(time, true)
                        m.ViewController.AddTimer(m.overlayTimer, m)
                    end if
                    m.overlayTimer.Active = true
                    m.overlayTimer.Mark()
                end if
            end if
        end if
    end if

    return handled
End Function


Sub photoPlayerShowContextMenu(obj,force_show = false)
    audioplayer = GetViewController().AudioPlayer

    ' show audio dialog if item is directory and audio is playing/paused
    if tostr(obj.nodename) = "Directory" then
        if audioplayer.IsPlaying or audioplayer.IsPaused or audioPlayer.ContextScreenID <> invalid then AudioPlayer.ShowContextMenu()
        return
    end if
   
    ' do not display if audio is playing - sorry, audio dialog overrides this, maybe work more logic in later
    ' I.E. show button for this dialog from audioplayer dialog
    if NOT force_show and  audioplayer.IsPlaying or audioplayer.IsPaused or audioPlayer.ContextScreenID <> invalid then 
        AudioPlayer.ShowContextMenu()
        return
    end if

    container = createPlexContainerForUrl(obj.server, obj.server.serverUrl, obj.key)
    if container <> invalid then
        container.getmetadata()
        ' only create dialog if metadata is available
        if type(container.metadata) = "roArray" and type(container.metadata[0].media) = "roArray" then 
            obj.MediaInfo = container.metadata[0].media[0]
            dialog = createBaseDialog()
            dialog.Title = "Image: " + obj.title
            dialog.text = ""
            ' NOTHING lines up in a dialog.. lovely        
            if obj.mediainfo.make <> invalid then dialog.text = dialog.text                  + "    camera: " + tostr(obj.mediainfo.make) + chr(10)
            if obj.mediainfo.model <> invalid then dialog.text = dialog.text                 + "      model: " + tostr(obj.mediainfo.model) + chr(10)
            if obj.mediainfo.lens <> invalid then dialog.text = dialog.text                  + "          lens: " + tostr(obj.mediainfo.lens) + chr(10)
            if obj.mediainfo.aperture <> invalid then dialog.text = dialog.text              + "  aperture: " + tostr(obj.mediainfo.aperture) + chr(10)
            if obj.mediainfo.exposure <> invalid then dialog.text = dialog.text              + " exposure: " + tostr(obj.mediainfo.exposure) + chr(10)
            if obj.mediainfo.iso <> invalid then dialog.text = dialog.text                   + "             iso: " + tostr(obj.mediainfo.iso) + chr(10)
            if obj.mediainfo.width <> invalid and obj.mediainfo.height <> invalid then dialog.text = dialog.text + "           size: " + tostr(obj.mediainfo.width) + " x " + tostr(obj.mediainfo.height) + chr(10)
            if obj.mediainfo.aspectratio <> invalid then dialog.text = dialog.text           + "      aspect: " + tostr(obj.mediainfo.aspectratio) + chr(10)
            if obj.mediainfo.container <> invalid then dialog.text = dialog.text             + "          type: " + tostr(obj.mediainfo.container) + chr(10)
            if obj.mediainfo.originallyAvailableAt <> invalid then dialog.text = dialog.text + "          date: "  + tostr(obj.mediainfo.originallyAvailableAt) + chr(10)
        
        
            dialog.SetButton("close", "Close")
        
            dialog.ParentScreen = m
            dialog.Show()
        end if
    end if

End Sub

sub photoPlayerOnTimerExpired(timer)
    if timer.Name = "overlay" then
        m.screen.SetTextOverlayIsVisible(false)
        m.screen.SetTextOverlayHoldTime(timer.time)
        m.overlayTimer.Active = false
    end if
End Sub
