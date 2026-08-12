import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Events } from '@wailsio/runtime'
import { RecorderService } from '../bindings/github.com/uniquejava/eggplant-recorder'
import type { MicDevice, Source } from '../bindings/github.com/uniquejava/eggplant-recorder/internal/capture/models'
import type { Clip } from '../bindings/github.com/uniquejava/eggplant-recorder/models'

type View = 'select' | 'recording' | 'editor'

function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0
  const m = Math.floor(seconds / 60)
  const s = seconds - m * 60
  return `${m}:${s.toFixed(1).padStart(4, '0')}`
}

function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0
  const total = Math.floor(seconds + 0.5)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  if (h > 0) {
    return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  }
  return `${m}:${String(s).padStart(2, '0')}`
}

function App() {
  const [view, setView] = useState<View>('select')
  const [sources, setSources] = useState<Source[]>([])
  const [selectedId, setSelectedId] = useState<string>('')
  const [systemAudio, setSystemAudio] = useState(true)
  const [microphone, setMicrophone] = useState(false)
  const [mics, setMics] = useState<MicDevice[]>([])
  const [micDeviceId, setMicDeviceId] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [needsScreenAccess, setNeedsScreenAccess] = useState(false)
  const [needsRelaunch, setNeedsRelaunch] = useState(false)

  const [mediaURL, setMediaURL] = useState('')
  const [duration, setDuration] = useState(0)
  const [clips, setClips] = useState<Clip[]>([])
  const [selectedClipId, setSelectedClipId] = useState('')
  const [currentTime, setCurrentTime] = useState(0)
  const [playing, setPlaying] = useState(false)

  const [elapsed, setElapsed] = useState(0)
  const [paused, setPaused] = useState(false)

  const videoRef = useRef<HTMLVideoElement | null>(null)
  const trackRef = useRef<HTMLDivElement | null>(null)
  const scrubbingRef = useRef(false)

  const selected = useMemo(
    () => sources.find((s) => s.id === selectedId),
    [sources, selectedId],
  )

  const applyFinished = useCallback((data: { mediaUrl: string; duration: number }) => {
    const id = `clip-${Date.now()}`
    setMediaURL(data.mediaUrl)
    setDuration(data.duration || 0)
    setClips([{
      id,
      start: 0,
      end: data.duration || 0,
      sourceUrl: data.mediaUrl,
    }])
    setSelectedClipId(id)
    setView('editor')
    setPlaying(false)
    setCurrentTime(0)
    setPaused(false)
    setElapsed(0)
  }, [])

  const refreshMics = useCallback(async () => {
    try {
      const list = (await RecorderService.ListMicrophones()) || []
      setMics(list)
      setMicDeviceId((prev) => {
        if (prev && list.some((m) => m.id === prev)) return prev
        const def = list.find((m) => m.default)
        return def?.id || list[0]?.id || ''
      })
    } catch {
      // listing can fail before mic permission; keep empty
    }
  }, [])

  const refreshSources = useCallback(async (opts?: { requestAccess?: boolean }) => {
    setLoading(true)
    setError('')
    try {
      let granted = await RecorderService.HasScreenAccess()
      if (!granted && opts?.requestAccess) {
        granted = await RecorderService.RequestScreenAccess()
      }

      // Do NOT call ListSources when preflight is false — on macOS 15,
      // SCShareableContent opens System Settings every time, which feels like spam.
      if (!granted) {
        setSources([])
        setSelectedId('')
        setNeedsScreenAccess(true)
        setNeedsRelaunch(false)
        return
      }

      let list: Source[] = []
      try {
        list = (await RecorderService.ListSources()) || []
      } catch (e: any) {
        setError(e?.message || String(e))
      }

      if (list.length) {
        setNeedsScreenAccess(false)
        setNeedsRelaunch(false)
        setSources(list)
        setSelectedId((prev) => (prev && list.some((s) => s.id === prev) ? prev : list[0].id))
        void (async () => {
          const targets = list.filter((s) => !s.thumbnail)
          const concurrency = 3
          let i = 0
          const worker = async () => {
            while (i < targets.length) {
              const idx = i++
              const source = targets[idx]
              try {
                const thumb = await RecorderService.GetSourceThumbnail(source.id, source.kind)
                if (!thumb) continue
                setSources((prev) =>
                  prev.map((s) => (s.id === source.id ? { ...s, thumbnail: thumb } : s)),
                )
              } catch {
                // ignore per-window preview failures
              }
            }
          }
          await Promise.all(Array.from({ length: concurrency }, () => worker()))
        })()
        return
      }

      setSources([])
      setSelectedId('')
      setNeedsScreenAccess(true)
      // Preflight true but empty list → this process still needs a full relaunch.
      setNeedsRelaunch(true)
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  const grantScreenAccess = async () => {
    setError('')
    try {
      const granted = await RecorderService.RequestScreenAccess()
      if (!granted) {
        await RecorderService.OpenScreenCaptureSettings()
      }
      await refreshSources()
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const openScreenSettings = async () => {
    setError('')
    try {
      await RecorderService.OpenScreenCaptureSettings()
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const relaunchApp = async () => {
    setError('')
    try {
      await RecorderService.Relaunch()
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  useEffect(() => {
    refreshSources()
    void refreshMics()
    const offFinished = Events.On('recording:finished', (ev: any) => {
      applyFinished(ev?.data || {})
    })
    const offFailed = Events.On('recording:failed', (ev: any) => {
      setError(ev?.data?.message || 'Recording failed')
      setView('select')
      setPaused(false)
      setElapsed(0)
    })
    const offStatus = Events.On('recording:status', (ev: any) => {
      const data = ev?.data
      if (!data) return
      setElapsed(data.elapsed || 0)
      setPaused(!!data.paused)
      if (data.recording) {
        setView((v) => (v === 'select' ? 'recording' : v))
      }
    })
    return () => {
      offFinished?.()
      offFailed?.()
      offStatus?.()
    }
  }, [refreshSources, refreshMics, applyFinished])

  useEffect(() => {
    if (view === 'editor' && clips.length && !clips.find((c) => c.id === selectedClipId)) {
      setSelectedClipId(clips[0].id)
    }
  }, [view, clips, selectedClipId])

  const startRecording = async () => {
    if (!selected) return
    setError('')
    try {
      if (microphone) {
        const ok = await RecorderService.RequestMicrophoneAccess()
        if (!ok) {
          setError('Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone.')
          return
        }
        await refreshMics()
      }
      await RecorderService.StartRecording({
        sourceId: selected.id,
        sourceKind: selected.kind,
        systemAudio,
        microphone,
        microphoneDeviceId: microphone ? micDeviceId : '',
      })
      setElapsed(0)
      setPaused(false)
      setView('recording')
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const stopRecording = async () => {
    setError('')
    try {
      const result = await RecorderService.StopRecording()
      applyFinished(result)
    } catch (e: any) {
      setError(e?.message || String(e))
      setView('select')
    }
  }

  const pauseRecording = async () => {
    setError('')
    try {
      await RecorderService.PauseRecording()
      setPaused(true)
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const resumeRecording = async () => {
    setError('')
    try {
      await RecorderService.ResumeRecording()
      setPaused(false)
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const togglePlay = async () => {
    const video = videoRef.current
    if (!video) return
    if (video.paused) {
      await video.play()
      setPlaying(true)
    } else {
      video.pause()
      setPlaying(false)
    }
  }

  const splitClip = () => {
    const t = currentTime
    const idx = clips.findIndex((c) => c.id === selectedClipId)
    if (idx < 0) return
    const clip = clips[idx]
    if (t <= clip.start + 0.05 || t >= clip.end - 0.05) return
    const left: Clip = { ...clip, id: `${clip.id}-a`, end: t }
    const right: Clip = { ...clip, id: `${clip.id}-b`, start: t }
    const next = [...clips.slice(0, idx), left, right, ...clips.slice(idx + 1)]
    setClips(next)
    setSelectedClipId(right.id)
    RecorderService.SetClips(next)
  }

  const deleteClip = () => {
    if (clips.length <= 1) return
    const next = clips.filter((c) => c.id !== selectedClipId)
    setClips(next)
    setSelectedClipId(next[0]?.id || '')
    RecorderService.SetClips(next)
  }

  const exportMP4 = async () => {
    setError('')
    try {
      await RecorderService.SetClips(clips)
      const path = await RecorderService.ExportVideo()
      if (!path) return
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const seekFromClientX = useCallback((clientX: number) => {
    const el = trackRef.current
    const video = videoRef.current
    if (!el || !video || duration <= 0) return
    const rect = el.getBoundingClientRect()
    if (rect.width <= 0) return
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width))
    const t = ratio * duration
    video.currentTime = t
    setCurrentTime(t)
  }, [duration])

  const onTrackPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    if (duration <= 0) return
    // Don't steal clicks from editor buttons; only scrub on the track.
    scrubbingRef.current = true
    e.currentTarget.setPointerCapture(e.pointerId)
    seekFromClientX(e.clientX)
  }

  const onTrackPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!scrubbingRef.current) return
    seekFromClientX(e.clientX)
  }

  const onTrackPointerUp = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!scrubbingRef.current) return
    scrubbingRef.current = false
    if (e.currentTarget.hasPointerCapture(e.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId)
    }
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (view === 'recording') {
        if (e.code === 'Space') {
          e.preventDefault()
          if (paused) resumeRecording()
          else pauseRecording()
        }
        return
      }
      if (view !== 'editor') return
      if (e.code === 'Space') {
        e.preventDefault()
        togglePlay()
      } else if (e.key === 's' || e.key === 'S') {
        splitClip()
      } else if (e.key === 'Backspace' || e.key === 'Delete') {
        deleteClip()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  })

  return (
    <div className="app">
      {view === 'select' && (
        <>
          <header className="header">
            <h1>Record your screen</h1>
            <p>Pick a screen or window, then hit record. Control from the menu bar tray.</p>
          </header>

          {loading ? (
            <div className="loading">Loading sources…</div>
          ) : needsScreenAccess ? (
            <div className="permission-panel">
              <h2>Screen Recording permission required</h2>
              {needsRelaunch ? (
                <p>
                  Permission looks enabled, but this running process still cannot see screens or windows.
                  Closing the window is not enough (the menu-bar tray keeps the app alive).
                  Click <strong>Relaunch</strong>, or Quit from the tray and open the app again.
                </p>
              ) : (
                <p>
                  macOS blocks the window list until this app is allowed under
                  System Settings → Privacy &amp; Security → Screen Recording.
                  Enable <strong>EggplantRecorder</strong>, then relaunch.
                  Tip: use a stable code signature (<code>./scripts/setup-dev-codesign.sh</code>)
                  so rebuilds do not require authorizing again.
                </p>
              )}
              <div className="permission-actions">
                {needsRelaunch ? (
                  <button className="btn btn-primary" onClick={relaunchApp}>Relaunch</button>
                ) : (
                  <button className="btn btn-primary" onClick={grantScreenAccess}>Grant access</button>
                )}
                <button className="btn btn-ghost" onClick={openScreenSettings}>Open Settings</button>
                <button className="btn btn-ghost" onClick={() => refreshSources()}>Reload sources</button>
              </div>
            </div>
          ) : (
            <div className="sources">
              {sources.map((source) => (
                <button
                  key={source.id}
                  className={`source-card ${selectedId === source.id ? 'selected' : ''}`}
                  onClick={() => setSelectedId(source.id)}
                >
                  {source.thumbnail ? (
                    <img className="thumb" src={`data:image/png;base64,${source.thumbnail}`} alt="" />
                  ) : (
                    <div className="thumb placeholder">{source.kind === 'screen' ? 'Screen' : 'Window'}</div>
                  )}
                  <div className="source-meta">
                    <span className="source-kind">{source.kind}</span>
                    <span className="source-name">{source.name}</span>
                  </div>
                </button>
              ))}
            </div>
          )}

          <div className="bottom-bar">
            <div className="toggles">
              <label>
                <input type="checkbox" checked={systemAudio} onChange={(e) => setSystemAudio(e.target.checked)} />
                System audio
              </label>
              <label>
                <input
                  type="checkbox"
                  checked={microphone}
                  onChange={(e) => {
                    const on = e.target.checked
                    setMicrophone(on)
                    if (on) void refreshMics()
                  }}
                />
                Microphone
              </label>
              {microphone && (
                <label className="mic-select-label">
                  Input
                  <select
                    className="mic-select"
                    value={micDeviceId}
                    onChange={(e) => setMicDeviceId(e.target.value)}
                    onFocus={() => void refreshMics()}
                  >
                    {mics.length === 0 && <option value="">Default microphone</option>}
                    {mics.map((m) => (
                      <option key={m.id} value={m.id}>
                        {m.name}{m.default ? ' (default)' : ''}
                      </option>
                    ))}
                  </select>
                </label>
              )}
            </div>
            <button className="btn btn-danger" disabled={!selected || loading} onClick={startRecording}>
              Record
            </button>
          </div>
          {error && <div className="error">{error}</div>}
        </>
      )}

      {view === 'recording' && (
        <div className="recording-view">
          <div className="recording-panel">
            <div className={`recording-status ${paused ? 'is-paused' : ''}`}>
              <span className={`rec-dot ${paused ? 'is-paused' : ''}`} />
              {paused ? 'Paused' : 'Recording'}
            </div>
            <div className="elapsed">{formatClock(elapsed)}</div>
            <div className="recording-actions">
              {paused ? (
                <button className="btn btn-primary" onClick={resumeRecording}>Resume</button>
              ) : (
                <button className="btn btn-ghost" onClick={pauseRecording}>Pause</button>
              )}
              <button className="btn btn-danger" onClick={stopRecording}>Stop</button>
            </div>
            <div className="hint">Menu bar shows elapsed time · Space to pause/resume</div>
            {error && <div className="error">{error}</div>}
          </div>
        </div>
      )}

      {view === 'editor' && (
        <div className="editor">
          <div className="preview">
            <video
              ref={videoRef}
              src={mediaURL}
              onTimeUpdate={(e) => setCurrentTime(e.currentTarget.currentTime)}
              onLoadedMetadata={(e) => {
                if (!duration) setDuration(e.currentTarget.duration || 0)
              }}
              onPlay={() => setPlaying(true)}
              onPause={() => setPlaying(false)}
              onEnded={() => setPlaying(false)}
            />
          </div>

          <div className="timeline-wrap">
            <div className="timeline-help">
              Drag the timeline or click to position · Backspace to delete the selected clip · Space play/pause · S to split
            </div>
            <div
              className="timeline-track"
              ref={trackRef}
              onPointerDown={onTrackPointerDown}
              onPointerMove={onTrackPointerMove}
              onPointerUp={onTrackPointerUp}
              onPointerCancel={onTrackPointerUp}
            >
              {clips.map((clip) => {
                const left = duration > 0 ? (clip.start / duration) * 100 : 0
                const width = duration > 0 ? ((clip.end - clip.start) / duration) * 100 : 100
                return (
                  <div
                    key={clip.id}
                    className={`clip ${selectedClipId === clip.id ? 'selected' : ''}`}
                    style={{ left: `${left}%`, width: `${Math.max(width, 0.5)}%` }}
                    onPointerDown={() => setSelectedClipId(clip.id)}
                  />
                )
              })}
              <div className="playhead" style={{ left: `${duration > 0 ? (currentTime / duration) * 100 : 0}%` }} />
            </div>
            <div className="timeline-labels">
              <span>0:00</span>
              <span>{formatTime(duration)}</span>
            </div>
          </div>

          <div className="editor-bar">
            <div className="editor-left">
              <button className="btn btn-ghost" onClick={togglePlay}>{playing ? 'Pause' : 'Play'}</button>
              <button className="btn btn-ghost" onClick={splitClip}>Split</button>
              <button className="btn btn-ghost" onClick={deleteClip} disabled={clips.length <= 1}>Delete clip</button>
              <span className="time-readout">{formatTime(currentTime)} / {formatTime(duration)}</span>
            </div>
            <div className="editor-right">
              <button className="btn btn-ghost" onClick={() => { setView('select'); refreshSources() }}>New recording</button>
              <button className="btn btn-primary" onClick={exportMP4}>Export MP4</button>
            </div>
          </div>
          {error && <div className="error">{error}</div>}
        </div>
      )}
    </div>
  )
}

export default App
