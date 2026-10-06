/**
 * The drawings beside each feature on the home page: small, static pictures of each plugin at
 * work, made from markup so they stay sharp and need no image files. They show example content
 * only, never anyone's real data.
 */

export function ClipboardVisual() {
  return (
    <ul className="mini-rows">
      <li className="selected">
        <span className="row-icon">¶</span>Invoice #2041 — due Oct 12
        <span className="row-meta">Mail</span>
      </li>
      <li>
        <span className="row-icon">▣</span>invoice-screenshot.png
        <span className="row-meta">Image</span>
      </li>
      <li>
        <span className="row-icon">¶</span>billing@acme.co<span className="row-meta">acme.co</span>
      </li>
      <li>
        <span className="row-icon">¶</span>Net 30, paid via ACH
        <span className="row-meta">Notes</span>
      </li>
    </ul>
  )
}

export function DictationVisual() {
  return (
    <>
      <div className="notch-mock">
        <span className="rec" />
        <span className="bars">
          {[0, 1, 2, 3, 4, 5, 6].map(bar => (
            <i key={bar} />
          ))}
        </span>
        <span>0:07</span>
      </div>
      <p className="mock-text">
        Thanks for the notes. I’ll send the revised draft by Thursday
        <span className="caret" />
      </p>
    </>
  )
}

export function WindowsVisual() {
  return (
    <>
      <div className="screen-mock">
        <div className="window-mock on">
          <b />
          <b style={{ width: '70%' }} />
          <b style={{ width: '50%' }} />
        </div>
        <div className="window-mock">
          <b />
          <b style={{ width: '60%' }} />
        </div>
      </div>
      <p className="visual-caption">Left half: ⌃⌥⌘← · Right half: ⌃⌥⌘→</p>
    </>
  )
}

export function ScreenshotVisual() {
  return (
    <div className="editor-mock">
      <div className="editor-bar">
        <span>Arrow</span>
        <span>Draw</span>
        <span>Text</span>
        <span className="on">Redact</span>
        <span>Blur</span>
        <span className="save">Save ↩</span>
      </div>
      <div className="shot-mock">
        <b style={{ width: '40%' }} />
        <b />
        <span className="redact" />
        <b style={{ width: '80%' }} />
        <span className="blur" />
        <b style={{ width: '55%' }} />
      </div>
    </div>
  )
}

export function SnippetsVisual() {
  return (
    <div className="expand-mock">
      <p className="mock-text">
        Hi Dana, <code>;ship</code>
      </p>
      <p className="visual-caption">expands to</p>
      <p className="mock-text">
        Hi Dana, your order shipped today. Tracking details are in the confirmation email.
      </p>
    </div>
  )
}
