import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Events } from '@wailsio/runtime'
import { RecorderService } from '../bindings/github.com/cyper/video-editor-wails'
import type { Source } from '../bindings/github.com/cyper/video-editor-wails/internal/capture/models'
import type { Clip } from '../bindings/github.com/cyper/video-editor-wails/models'

type View = 'select' | 'recording' | 'editor'
function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0
  const m = Math.floor(seconds / 60)
  const s = seconds - m * 60
  return `${m}:${s.toFixed(1).padStart(4, '0')}`
}

function App() {
  const [view, setView] = useState<View>('select')
  const [sources, setSources] = useState<Source[]>([])
  const [selectedId, setSelectedId] = useState<string>('')
  const [systemAudio, setSystemAudio] = useState(true)
  const [microphone, setMicrophone] = useState(false)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)

  const [mediaURL, setMediaURL] = useState('')
  const [duration, setDuration] = useState(0)
  const [clips, setClips] = useState<Clip[]>([])
  const [selectedClipId, setSelectedClipId] = useState('')
  const [currentTime, setCurrentTime] = useState(0)
  const [playing, setPlaying] = useState(false)

  const videoRef = useRef<HTMLVideoElement | null>(null)
  const trackRef = useRef<HTMLDivElement | null>(null)

  const selected = useMemo(
    () => sources.find((s) => s.id === selectedId),
    [sources, selectedId],
  )

  const refreshSources = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await RecorderService.RequestScreenAccess()
      const list = await RecorderService.ListSources()
      setSources(list || [])
      if (list?.length) {
        setSelectedId((prev) => prev || list[0].id)
      }
    } catch (e: any) {
      setError(e?.message || String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    refreshSources()
    const offFinished = Events.On('recording:finished', (ev: any) => {
      const data = ev?.data
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
    })
    const offFailed = Events.On('recording:failed', (ev: any) => {
      setError(ev?.data?.message || 'Recording failed')
      setView('select')
    })
    return () => {
      offFinished?.()
      offFailed?.()
    }
  }, [refreshSources])

  // Fix selected clip id after recording finished (avoid stale id from above)
  useEffect(() => {
    if (view === 'editor' && clips.length && !clips.find((c) => c.id === selectedClipId)) {
      setSelectedClipId(clips[0].id)
    }
  }, [view, clips, selectedClipId])

  const startRecording = async () => {
    if (!selected) return
    setError('')
    try {
      await RecorderService.StartRecording({
        sourceId: selected.id,
        sourceKind: selected.kind,
        systemAudio,
        microphone,
      })
      setView('recording')
    } catch (e: any) {
      setError(e?.message || String(e))
    }
  }

  const stopRecording = async () => {
    setError('')
    try {
      const result = await RecorderService.StopRecording()
      setMediaURL(result.mediaUrl)
      setDuration(result.duration || 0)
      const clip: Clip = {
        id: `clip-${Date.now()}`,
        start: 0,
        end: result.duration || 0,
        sourceUrl: result.mediaUrl,
      }
      setClips([clip])
      setSelectedClipId(clip.id)
      setView('editor')
    } catch (e: any) {
      setError(e?.message || String(e))
      setView('select')
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

  const onTrackClick = (e: React.MouseEvent) => {
    const el = trackRef.current
    const video = videoRef.current
    if (!el || !video || duration <= 0) return
    const rect = el.getBoundingClientRect()
    const ratio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width))
    video.currentTime = ratio * duration
    setCurrentTime(video.currentTime)
  }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
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
            <p>Pick a screen or window, then hit record. Stop from the menu bar.</p>
          </header>

          {loading ? (
            <div className="loading">Loading sources… Grant Screen Recording permission if prompted.</div>
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
                <input type="checkbox" checked={microphone} onChange={(e) => setMicrophone(e.target.checked)} />
                Microphone
              </label>
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
            <div className="recording-status">
              <span className="rec-dot" />
              Recording…
            </div>
            <button className="btn btn-danger" onClick={stopRecording}>Stop recording</button>
            <div className="hint">or use the screen-recording indicator in the menu bar</div>
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
            <div className="timeline-track" ref={trackRef} onClick={onTrackClick}>
              {clips.map((clip) => {
                const left = duration > 0 ? (clip.start / duration) * 100 : 0
                const width = duration > 0 ? ((clip.end - clip.start) / duration) * 100 : 100
                return (
                  <div
                    key={clip.id}
                    className={`clip ${selectedClipId === clip.id ? 'selected' : ''}`}
                    style={{ left: `${left}%`, width: `${Math.max(width, 0.5)}%` }}
                    onClick={(e) => {
                      e.stopPropagation()
                      setSelectedClipId(clip.id)
                    }}
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
