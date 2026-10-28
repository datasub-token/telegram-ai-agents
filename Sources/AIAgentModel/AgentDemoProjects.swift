import Foundation

#if targetEnvironment(simulator) || os(macOS)

/// The small projects the demo agent hands back. Deliberately plain: the product is the chat, not these apps. Each is a
/// Telegram Mini App that follows the host's theme through the `--tg-theme-*` variables.
enum AgentDemoProjects {
    enum Kind {
        case game
        case site
        case miniApp
    }

    static func files(kind: Kind, title: String) -> [AgentArtifactFile] {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        func fill(_ text: String) -> String {
            return text.replacingOccurrences(of: "{{TITLE}}", with: escapedTitle)
        }
        switch kind {
        case .game:
            return [
                AgentArtifactFile(name: "index.html", language: "html", text: fill(gameHTML)),
                AgentArtifactFile(name: "style.css", language: "css", text: baseCSS + gameCSS),
                AgentArtifactFile(name: "app.js", language: "javascript", text: gameJS)
            ]
        case .site:
            return [
                AgentArtifactFile(name: "index.html", language: "html", text: fill(siteHTML)),
                AgentArtifactFile(name: "style.css", language: "css", text: baseCSS + siteCSS)
            ]
        case .miniApp:
            return [
                AgentArtifactFile(name: "index.html", language: "html", text: fill(appHTML)),
                AgentArtifactFile(name: "style.css", language: "css", text: baseCSS + appCSS),
                AgentArtifactFile(name: "app.js", language: "javascript", text: appJS)
            ]
        }
    }

    /// What the card's preview shows instead of the start screen: the game in play, the list with entries.
    static func previewScript(kind: Kind) -> String? {
        switch kind {
        case .game:
            return gamePreviewJS
        case .site:
            return nil
        case .miniApp:
            return appPreviewJS
        }
    }

    private static let gamePreviewJS = #"""
overlay.style.display = 'none';
score = 12;
lives = 2;
scoreLabel.textContent = String(score);
renderLives();
function drawPreviewFrame() {
  resize();
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  stars = [
    [0.12, 0.24, 15, 0.3], [0.36, 0.14, 11, 1.2], [0.6, 0.34, 17, 0.6], [0.86, 0.18, 12, 2.4],
    [0.22, 0.68, 13, 2.1], [0.5, 0.78, 16, 0.9], [0.78, 0.64, 14, 1.7]
  ].map(([x, y, size, spin]) => ({ x: x * width, y: y * height, size, speed: 0, spin }));
  context.clearRect(0, 0, width, height);
  stars.forEach(drawStar);
}
drawPreviewFrame();
window.addEventListener('resize', drawPreviewFrame);
"""#

    private static let appPreviewJS = #"""
items = [
  { text: 'Sketch out the week', done: false },
  { text: 'Call the studio at 3 pm', done: false },
  { text: 'Reply to emails', done: true }
];
render();
"""#

    private static let baseCSS = #"""
:root {
  --fallback-bg: #ffffff;
  --fallback-text: #000000;
  --fallback-hint: #8e8e93;
  --fallback-section: #f2f2f7;
  --fallback-button: #3390ec;
  --bg: var(--tg-theme-bg-color, var(--fallback-bg));
  --text: var(--tg-theme-text-color, var(--fallback-text));
  --hint: var(--tg-theme-hint-color, var(--fallback-hint));
  --section: var(--tg-theme-section-bg-color, var(--fallback-section));
  --button: var(--tg-theme-button-color, var(--fallback-button));
  --button-text: var(--tg-theme-button-text-color, #ffffff);
  --accent: var(--tg-theme-accent-text-color, var(--button));
}

@media (prefers-color-scheme: dark) {
  :root {
    --fallback-bg: #1c1c1e;
    --fallback-text: #ffffff;
    --fallback-hint: #98989e;
    --fallback-section: #2c2c2e;
  }
}

* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }

body {
  margin: 0;
  padding: env(safe-area-inset-top) 16px env(safe-area-inset-bottom);
  background: var(--bg);
  color: var(--text);
  font: 16px/1.4 -apple-system, system-ui, sans-serif;
}

h1 { margin: 0; font-size: 22px; font-weight: 700; }
.hint { margin: 2px 0 0; color: var(--hint); font-size: 14px; }

.button {
  border: 0;
  border-radius: 12px;
  padding: 14px 20px;
  background: var(--button);
  color: var(--button-text);
  font: inherit;
  font-weight: 600;
  transition: transform 0.15s ease;
}
.button:active { transform: scale(0.97); }

"""#

    private static let gameHTML = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
  <title>{{TITLE}}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="bar">
    <div>
      <h1>{{TITLE}}</h1>
      <p class="hint">Catch the stars before they fall</p>
    </div>
    <div class="score"><span id="score">0</span><small>points</small></div>
  </header>
  <div class="lives" id="lives"></div>
  <canvas id="field"></canvas>
  <div class="overlay" id="overlay">
    <h2 id="overlay-title">Ready?</h2>
    <p id="overlay-text">Tap the stars to catch them. Miss three and the game is over.</p>
    <button class="button" id="start">Play</button>
  </div>
  <script src="app.js"></script>
</body>
</html>
"""#

    private static let gameCSS = #"""
body { height: 100vh; overflow: hidden; display: flex; flex-direction: column; }

.bar { display: flex; align-items: center; justify-content: space-between; padding: 16px 0 8px; }

.score { display: flex; flex-direction: column; align-items: flex-end; }
.score span { font-size: 28px; font-weight: 700; font-variant-numeric: tabular-nums; }
.score small { color: var(--hint); font-size: 12px; }

.lives { display: flex; gap: 6px; height: 10px; }
.lives i { width: 10px; height: 10px; border-radius: 5px; background: var(--accent); transition: opacity 0.3s; }
.lives i.lost { opacity: 0.2; }

canvas { flex: 1; width: 100%; margin: 12px 0 16px; border-radius: 16px; background: var(--tg-theme-secondary-bg-color, var(--section)); }

.overlay {
  position: fixed; inset: 0;
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  padding: 32px; text-align: center;
  background: color-mix(in srgb, var(--bg) 88%, transparent);
  transition: opacity 0.25s;
}
.overlay.hidden { opacity: 0; pointer-events: none; }
.overlay h2 { margin: 0 0 8px; font-size: 26px; }
.overlay p { margin: 0 0 24px; color: var(--hint); }
"""#

    private static let gameJS = #"""
const canvas = document.getElementById('field');
const context = canvas.getContext('2d');
const scoreLabel = document.getElementById('score');
const livesRow = document.getElementById('lives');
const overlay = document.getElementById('overlay');
const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#3390ec';

let stars = [];
let score = 0;
let lives = 3;
let running = false;
let lastSpawn = 0;
let lastFrame = 0;

function resize() {
  const ratio = window.devicePixelRatio || 1;
  canvas.width = canvas.clientWidth * ratio;
  canvas.height = canvas.clientHeight * ratio;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
}

function renderLives() {
  livesRow.innerHTML = '';
  for (let i = 0; i < 3; i++) {
    const dot = document.createElement('i');
    if (i >= lives) dot.className = 'lost';
    livesRow.appendChild(dot);
  }
}

function spawn() {
  const size = 14 + Math.random() * 10;
  stars.push({
    x: size + Math.random() * (canvas.clientWidth - size * 2),
    y: -size,
    size,
    speed: 70 + Math.random() * 60 + score * 2,
    spin: Math.random() * Math.PI
  });
}

function drawStar(star) {
  context.save();
  context.translate(star.x, star.y);
  context.rotate(star.spin);
  context.beginPath();
  for (let i = 0; i < 10; i++) {
    const radius = i % 2 === 0 ? star.size : star.size * 0.45;
    const angle = (Math.PI / 5) * i;
    context.lineTo(Math.sin(angle) * radius, -Math.cos(angle) * radius);
  }
  context.closePath();
  context.fillStyle = accent;
  context.fill();
  context.restore();
}

function frame(time) {
  if (!running) return;
  const delta = Math.min(0.05, (time - lastFrame) / 1000);
  lastFrame = time;
  if (time - lastSpawn > Math.max(380, 900 - score * 15)) {
    spawn();
    lastSpawn = time;
  }
  context.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);
  for (const star of stars) {
    star.y += star.speed * delta;
    star.spin += delta;
    drawStar(star);
  }
  const fallen = stars.filter((star) => star.y - star.size > canvas.clientHeight);
  if (fallen.length > 0) {
    stars = stars.filter((star) => !fallen.includes(star));
    lives -= fallen.length;
    renderLives();
    if (lives <= 0) return finish();
  }
  requestAnimationFrame(frame);
}

function start() {
  stars = [];
  score = 0;
  lives = 3;
  scoreLabel.textContent = '0';
  renderLives();
  overlay.classList.add('hidden');
  running = true;
  lastFrame = performance.now();
  requestAnimationFrame(frame);
}

function finish() {
  running = false;
  document.getElementById('overlay-title').textContent = 'Game over';
  document.getElementById('overlay-text').textContent = 'Stars caught: ' + score;
  document.getElementById('start').textContent = 'Play again';
  overlay.classList.remove('hidden');
}

canvas.addEventListener('pointerdown', (event) => {
  const rect = canvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  const hit = stars.find((star) => Math.hypot(star.x - x, star.y - y) < star.size + 12);
  if (hit) {
    stars = stars.filter((star) => star !== hit);
    score += 1;
    scoreLabel.textContent = String(score);
    window.Telegram?.WebApp?.HapticFeedback?.impactOccurred('light');
  }
});

document.getElementById('start').addEventListener('click', start);
window.addEventListener('resize', resize);
resize();
renderLives();
"""#

    private static let siteHTML = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{{TITLE}}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <section class="hero">
    <p class="eyebrow">Welcome</p>
    <h1>{{TITLE}}</h1>
    <p class="hint">Everything you need to know, on one page.</p>
    <a class="button" href="#contact">Get in touch</a>
  </section>
  <section class="features">
    <article><h3>Fast</h3><p class="hint">Opens instantly, right inside Telegram.</p></article>
    <article><h3>Easy</h3><p class="hint">Big buttons and clear navigation.</p></article>
    <article><h3>Beautiful</h3><p class="hint">Follows your Telegram theme.</p></article>
  </section>
  <section class="contact" id="contact">
    <h2>Questions?</h2>
    <p class="hint">Write to us and we will reply within a day.</p>
    <a class="button" href="#">Write to us</a>
  </section>
</body>
</html>
"""#

    private static let siteCSS = #"""
.hero { padding: 48px 0 32px; }
.eyebrow { margin: 0 0 8px; color: var(--accent); font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.4px; }
.hero h1 { font-size: 34px; line-height: 1.15; }
.hero .hint { margin: 12px 0 24px; font-size: 17px; }
.button { display: inline-block; text-decoration: none; }

.features { display: grid; gap: 12px; }
.features article { padding: 16px; border-radius: 16px; background: var(--section); }
.features h3 { margin: 0 0 4px; font-size: 17px; }
.features p { margin: 0; }

.contact { margin: 32px 0; padding: 24px 16px; border-radius: 16px; background: var(--section); text-align: center; }
.contact h2 { margin: 0 0 6px; font-size: 22px; }
.contact .hint { margin: 0 0 20px; }
"""#

    private static let appHTML = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
  <title>{{TITLE}}</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="header">
    <h1>{{TITLE}}</h1>
    <p class="hint" id="counter">No entries yet</p>
  </header>
  <form class="composer" id="composer">
    <input id="field" placeholder="New entry" autocomplete="off">
    <button class="button" type="submit">Add</button>
  </form>
  <ul class="list" id="list"></ul>
  <script src="app.js"></script>
</body>
</html>
"""#

    private static let appCSS = #"""
.header { padding: 20px 0 12px; }

.composer { display: flex; gap: 8px; margin-bottom: 16px; }
.composer input {
  flex: 1; min-width: 0;
  border: 0; border-radius: 12px; padding: 0 14px;
  background: var(--section); color: var(--text); font: inherit;
}

.list { margin: 0; padding: 0; list-style: none; border-radius: 16px; overflow: hidden; background: var(--section); }
.list li { display: flex; align-items: center; gap: 12px; padding: 13px 16px; }
.list li + li { border-top: 1px solid color-mix(in srgb, var(--hint) 25%, transparent); }
.list li.done span { color: var(--hint); text-decoration: line-through; }
.list .check { width: 22px; height: 22px; border-radius: 11px; border: 1.5px solid var(--hint); flex: none; transition: background 0.2s, border-color 0.2s; }
.list li.done .check { background: var(--accent); border-color: var(--accent); }
"""#

    private static let appJS = #"""
const list = document.getElementById('list');
const field = document.getElementById('field');
const counter = document.getElementById('counter');
let items = JSON.parse(localStorage.getItem('items') || '[]');

function save() {
  localStorage.setItem('items', JSON.stringify(items));
}

function render() {
  list.innerHTML = '';
  items.forEach((item, index) => {
    const row = document.createElement('li');
    row.className = item.done ? 'done' : '';
    row.innerHTML = '<i class="check"></i><span></span>';
    row.querySelector('span').textContent = item.text;
    row.addEventListener('click', () => {
      items[index].done = !items[index].done;
      save();
      render();
    });
    list.appendChild(row);
  });
  const left = items.filter((item) => !item.done).length;
  counter.textContent = items.length === 0 ? 'No entries yet' : left + ' of ' + items.length + ' left';
  list.style.display = items.length === 0 ? 'none' : 'block';
}

document.getElementById('composer').addEventListener('submit', (event) => {
  event.preventDefault();
  const text = field.value.trim();
  if (!text) return;
  items.unshift({ text, done: false });
  field.value = '';
  save();
  render();
});

render();
"""#
}

#endif

extension AgentArtifact {
    /// The entry HTML with its stylesheets and scripts inlined, ready for `loadHTMLString`. `themeCSS` (a `:root { … }`
    /// block with the Mini App theme variables) goes first into `<head>`.
    /// `stillFrame` adds the preview script, for the card's picture of the project.
    public func assembledHTML(themeCSS: String, stillFrame: Bool = false) -> String? {
        guard var html = self.entryFile?.text else {
            return nil
        }
        for file in self.files where file.name != self.entryFileName {
            if file.language == "css" {
                html = html.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"\(file.name)\">", with: "<style>\n\(file.text)\n</style>")
            } else if file.language == "javascript" {
                html = html.replacingOccurrences(of: "<script src=\"\(file.name)\"></script>", with: "<script>\n\(file.text)\n</script>")
            }
        }
        if !themeCSS.isEmpty, let range = html.range(of: "<head>") {
            html.insert(contentsOf: "\n<style>\(themeCSS)</style>", at: range.upperBound)
        }
        if stillFrame, let previewScript = self.previewScript, let range = html.range(of: "</body>", options: .backwards) {
            html.insert(contentsOf: "<script>\n\(previewScript)\n</script>\n", at: range.lowerBound)
        }
        return html
    }
}
