import os
import sys
import threading
import subprocess
import re
import base64
import urllib.parse
import shutil
import requests
import webview
import webbrowser

# ----------------- Paths helpers -----------------


def get_run_dir():
    """Directory where bundled resources live (Nuitka temp / script dir)."""
    return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))


def get_app_dir():
    """Directory where the EXE (or script) actually resides (persistent)."""
    return os.path.dirname(os.path.abspath(sys.argv[0]))


# ----------------- GitHub config -----------------

GITHUB_OWNER = "3circledesign"
GITHUB_REPO = "Barry-sGameStore"
GITHUB_BRANCH = "FC26"

# Files in Barry-sGameStore/FC26
GITHUB_DOWNLOAD_BAT_PATH = "download.bat"
GITHUB_UNRAR_PATH = "UnRAR.exe"

# Folders in Barry-sGameStore/FC26 to bootstrap each app start
BOOTSTRAP_FOLDERS = [
    ("DepotDownloaderMod", "DepotDownloaderMod"),
    ("EA SPORTS FC 26 Manifests and Keys", "EA SPORTS FC 26 Manifests and Keys"),
]

# Fussboll repo for the 5 rar parts
FUSS_OWNER = "3circledesign"
FUSS_REPO = "fussboll"
FUSS_BRANCH = "Foosball26"
FOOS_PART_FILES = [
    "Foosball26.part1.rar",
    "Foosball26.part2.rar",
    "Foosball26.part3.rar",
    "Foosball26.part4.rar",
    "Foosball26.part5.rar",
]

DISCORD_INVITE = "https://discord.com/invite/cKKM2hyd4d"

# ----------------- HTML (Steam-styled UI with intro + completion popup) -----------------
HTML_RAW = r"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>EA SPORTS FC 26 • Download Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Manrope:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #101822;
    --accent: #66c0f4;
    --accent-soft: rgba(102,192,244,0.18);
    --accent-strong: #1b95de;
    --text: #e5f4ff;
    --muted: #aeb8c5;
    --danger: #ff7676;
    --warning: #ffd066;
    --panel-border: #27394a;
    --panel-bg: rgba(16,24,32,0.94);
    --panel-glow: rgba(102,192,244,0.18);
    --log-bg: #000814;
  }

  * {
    box-sizing: border-box;
  }
  html, body {
    margin: 0;
    padding: 0;
    height: 100%;
    font-family: "Manrope", system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    font-size: 14px;
    color: var(--text);
    background:
      radial-gradient(circle at top left, #182635 0, transparent 55%),
      radial-gradient(circle at bottom right, #050b13 0, transparent 55%),
      var(--bg);
    overflow: hidden;
  }
  body::before {
    content: "";
    position: fixed;
    inset: -40%;
    background:
      radial-gradient(circle at 10% 0%, rgba(102,192,244,0.32) 0, transparent 55%),
      radial-gradient(circle at 80% 100%, rgba(40,178,120,0.18) 0, transparent 55%);
    opacity: 0.9;
    filter: blur(6px);
    z-index: -1;
    animation: bgFloat 20s linear infinite alternate;
  }
  @keyframes bgFloat {
    from { transform: translate3d(-8px, -6px, 0) scale(1); }
    to   { transform: translate3d(8px, 6px, 0) scale(1.02); }
  }

  .app-root {
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
  }

  /* Seamless main card */
  .card {
    width: 880px;
    max-width: 880px;
    max-height: 620px;
    background: transparent;
    border-radius: 0;
    border: none;
    box-shadow: none;
    padding: 22px 24px 20px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    position: relative;
    overflow: hidden;
  }

  .card-header {
    display: flex;
    align-items: center;
    gap: 14px;
    position: relative;
    z-index: 1;
  }

  .logo-pill {
    width: 56px;
    height: 56px;
    border-radius: 18px;
    background: radial-gradient(circle at 20% 20%, #1b2838 0, #2a475e 40%, #0b141d 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow:
      0 0 0 2px rgba(2,6,12,0.9),
      0 12px 30px rgba(1,3,8,0.95),
      0 0 24px rgba(102,192,244,0.8);
    position: relative;
    overflow: hidden;
  }
  .logo-pulse {
    position: absolute;
    width: 140%;
    height: 140%;
    border-radius: inherit;
    background: radial-gradient(circle, rgba(102,192,244,0.5) 0, transparent 60%);
    opacity: 0;
    animation: pulse 2.4s ease-out infinite;
  }
  @keyframes pulse {
    0%   { transform: scale(0.7); opacity: 0.7; }
    70%  { transform: scale(1.1); opacity: 0; }
    100% { transform: scale(1.25); opacity: 0; }
  }
  .logo-img {
    position: relative;
    width: 34px;
    height: 34px;
    border-radius: 10px;
    object-fit: contain;
    box-shadow:
      0 0 0 2px rgba(102,192,244,0.9),
      0 8px 16px rgba(0,0,0,1);
    background: #050b13;
  }

  .title-block {
    flex: 1;
  }
  .title-row {
    display: flex;
    align-items: baseline;
    gap: 6px;
    flex-wrap: wrap;
  }
  .title-main {
    font-size: 21px;
    font-weight: 700;
    letter-spacing: -0.02em;
  }
  .title-tagline {
    font-size: 13px;
    color: var(--muted);
  }
  .title-sub {
    margin-top: 4px;
    font-size: 12px;
    color: var(--muted);
  }
  .title-sub strong {
    color: var(--accent);
  }

  .badge {
    padding: 6px 11px;
    font-size: 11px;
    border-radius: 999px;
    border: 1px solid rgba(102,192,244,0.65);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--accent);
    background: radial-gradient(circle at 0 0, rgba(1,18,34,0.9), rgba(5,11,19,0.95));
    box-shadow: 0 0 14px rgba(0,0,0,0.7);
  }
  .badge span {
    color: var(--accent);
  }

  .card-body {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 16px;
    align-items: stretch;
    position: relative;
    z-index: 1;
  }

  .panel {
    background: linear-gradient(145deg, rgba(9,20,32,0.98), rgba(9,15,24,0.98));
    border-radius: 18px;
    border: 1px solid var(--panel-border);
    box-shadow:
      0 18px 40px rgba(0,0,0,0.9),
      0 0 0 1px rgba(102,192,244,0.15);
    padding: 14px 14px 12px;
    position: relative;
    overflow: hidden;
  }
  .panel::before {
    content: "";
    position: absolute;
    inset: 0;
    background: radial-gradient(circle at 0 0, var(--panel-glow), transparent 60%);
    opacity: 0.9;
    mix-blend-mode: soft-light;
    pointer-events: none;
  }

  .section-title {
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.12em;
    color: var(--muted);
    margin-bottom: 8px;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .section-title-dot {
    width: 7px;
    height: 7px;
    border-radius: 999px;
    background: var(--accent);
    box-shadow: 0 0 12px rgba(102,192,244,1);
  }

  .status-row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 8px;
    gap: 10px;
  }
  .status-text {
    font-size: 13px;
    color: var(--muted);
  }
  .status-text strong {
    color: var(--accent);
  }
  .status-chip {
    font-size: 11px;
    padding: 4px 9px;
    border-radius: 999px;
    background: radial-gradient(circle at 0 0, #050b13 0, #050b13 45%, #020509 100%);
    border: 1px solid var(--panel-border);
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 10px rgba(102,192,244,1);
  }
  .status-chip[data-state="idle"] .status-dot {
    background: var(--muted);
    box-shadow: none;
  }
  .status-chip[data-state="error"] .status-dot {
    background: var(--danger);
    box-shadow: 0 0 14px rgba(255,118,118,1);
  }
  .status-chip[data-state="done"] .status-dot {
    background: var(--accent-strong);
    box-shadow: 0 0 14px rgba(102,192,244,1);
  }

  .progress-bar {
    position: relative;
    width: 100%;
    height: 15px;
    border-radius: 999px;
    background: radial-gradient(circle at top, #1b2838 0, #050b13 60%);
    overflow: hidden;
    border: 1px solid #1b2838;
    box-shadow: inset 0 0 10px rgba(0,0,0,1);
  }
  .progress-inner {
    position: absolute;
    inset: 1px;
    border-radius: inherit;
    overflow: hidden;
  }
  .progress-fill {
    position: absolute;
    inset: 0;
    width: 0%;
    border-radius: inherit;
    background: linear-gradient(90deg,#66c0f4,#1b95de,#66c0f4);
    background-size: 260% 100%;
    box-shadow:
      0 0 14px rgba(102,192,244,0.9),
      0 0 40px rgba(0,0,0,0.9);
    transition: width 0.45s cubic-bezier(0.22, 0.61, 0.36, 1);
    animation: shine 3.5s linear infinite;
  }
  @keyframes shine {
    0%   { background-position: 0% 50%; }
    100% { background-position: -200% 50%; }
  }
  .progress-stripes {
    position: absolute;
    inset: 0;
    background-image: linear-gradient(120deg,
      rgba(5,11,19,0.6) 25%,
      transparent 25%,
      transparent 50%,
      rgba(5,11,19,0.6) 50%,
      rgba(5,11,19,0.6) 75%,
      transparent 75%,
      transparent);
    background-size: 30px 30px;
    opacity: 0.3;
    mix-blend-mode: soft-light;
    animation: moveStripes 1.2s linear infinite;
  }
  @keyframes moveStripes {
    0%   { background-position: 0 0; }
    100% { background-position: 30px 0; }
  }

  .progress-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 6px;
    font-size: 12px;
    color: var(--muted);
  }
  .progress-percent {
    font-variant-numeric: tabular-nums;
    font-weight: 600;
    color: var(--accent);
  }
  .progress-note {
    font-size: 11px;
    opacity: 0.85;
  }

  .controls {
    margin-top: 10px;
    display: flex;
    gap: 8px;
    align-items: center;
    flex-wrap: wrap;
  }

  button {
    border: none;
    outline: none;
    cursor: pointer;
    font-family: inherit;
  }

  .btn-primary {
    position: relative;
    padding: 9px 18px;
    border-radius: 999px;
    background: linear-gradient(135deg,#66c0f4,#1b95de);
    color: #02050a;
    font-size: 13px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    box-shadow:
      0 12px 30px rgba(0,0,0,0.8),
      0 0 0 1px rgba(13,71,161,0.8);
    display: inline-flex;
    align-items: center;
    gap: 8px;
    transition:
      transform 0.12s ease-out,
      box-shadow 0.12s ease-out,
      filter 0.12s ease-out,
      opacity 0.2s ease-out;
  }
  .btn-primary:disabled {
    cursor: default;
    opacity: 0.85;
    box-shadow:
      0 6px 18px rgba(0,0,0,0.8),
      0 0 0 1px rgba(25,118,210,0.9);
    filter: grayscale(0.15);
  }
  .btn-primary:not(:disabled):active {
    transform: translateY(1px) scale(0.99);
    box-shadow:
      0 6px 16px rgba(0,0,0,0.9),
      0 0 0 1px rgba(30,136,229,1);
  }
  .btn-primary-icon {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    border: 2px solid rgba(5,15,32,0.9);
    background: radial-gradient(circle at 30% 30%, #e0f3ff 0, #66c0f4 55%, #1b95de 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    position: relative;
    overflow: hidden;
    font-size: 11px;
    font-weight: 700;
  }
  .btn-primary-icon::before {
    content: "";
    position: absolute;
    width: 140%;
    height: 140%;
    background: conic-gradient(
      from 0deg,
      rgba(5,15,32,0.0) 0deg,
      rgba(5,15,32,0.65) 120deg,
      rgba(5,15,32,0.0) 150deg);
    animation: spinArc 2.2s linear infinite;
    opacity: 0;
  }
  .btn-primary[data-working="true"] .btn-primary-icon::before {
    opacity: 1;
  }
  @keyframes spinArc {
    0%   { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
  }

  .btn-secondary {
    padding: 8px 12px;
    border-radius: 999px;
    background: radial-gradient(circle at 0 0,#050b13 0,#050b13 60%,#020408 100%);
    border: 1px solid #27394a;
    color: var(--muted);
    font-size: 11px;
    display: inline-flex;
    align-items: center;
    gap: 6px;
    opacity: 0.9;
  }
  .btn-secondary-icon {
    width: 8px;
    height: 8px;
    border-radius: 1px;
    border: 1px solid rgba(102,192,244,0.7);
    box-shadow: inset 0 0 0 1px rgba(1,4,8,0.9);
  }

  .log-panel-content {
    position: relative;
    z-index: 1;
    display: flex;
    flex-direction: column;
    height: 100%;
    margin-top: 14px;
  }
  .log-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 6px;
    gap: 8px;
  }
  .log-hint {
    font-size: 11px;
    color: var(--muted);
  }

  .log-summary {
    display: grid;
    grid-template-columns: 1.2fr 1.4fr 0.7fr;
    gap: 8px;
    margin-bottom: 8px;
  }
  .log-summary-item {
    background: radial-gradient(circle at 0 0,#040813 0,#020308 65%);
    border-radius: 10px;
    border: 1px solid #27394a;
    padding: 6px 8px;
    font-size: 11px;
  }
  .log-summary-label {
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-size: 10px;
    margin-bottom: 2px;
  }
  .log-summary-value {
    font-size: 11px;
    color: #d8e7ff;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .log-summary-value[data-state="ok"] {
    color: var(--accent);
  }
  .log-summary-value[data-state="error"] {
    color: var(--danger);
  }
  .log-summary-value[data-state="progress"] {
    color: var(--warning);
  }

  .log-box {
    flex: 1;
    min-height: 150px;
    max-height: 230px;
    background: var(--log-bg);
    border-radius: 12px;
    border: 1px solid #111827;
    padding: 8px 10px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    font-size: 12px;
    color: #e5e7eb;
    overflow: auto;
    white-space: pre-wrap;
    line-height: 1.4;
    box-shadow: inset 0 0 16px rgba(0,0,0,1);
  }
  .log-box::-webkit-scrollbar {
    width: 6px;
  }
  .log-box::-webkit-scrollbar-track {
    background: #020617;
  }
  .log-box::-webkit-scrollbar-thumb {
    background: #4b5563;
    border-radius: 999px;
  }

  .card-footer {
    margin-top: 2px;
    font-size: 11px;
    color: var(--muted);
    display: flex;
    justify-content: space-between;
    gap: 10px;
    align-items: center;
  }
  .footer-left {
    display: flex;
    gap: 8px;
    align-items: center;
    flex-wrap: nowrap;
  }
  .footer-pill {
    padding: 4px 8px;
    border-radius: 999px;
    background: radial-gradient(circle at 0 0,#050b13 0,#050b13 70%,#000000 100%);
    border: 1px solid #27394a;
    font-size: 10px;
    white-space: nowrap;
  }
  .footer-right {
    opacity: 0.9;
    white-space: nowrap;
  }

  /* ------------ Intro overlay (bootstrap) ------------ */
  .intro-overlay {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(circle at top left, rgba(15,23,42,0.96) 0, rgba(3,7,18,0.98) 55%),
      radial-gradient(circle at bottom right, rgba(15,23,42,0.96) 0, rgba(3,7,18,0.98) 55%);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 999;
    transition: opacity 0.4s ease-out;
  }
  .intro-inner {
    text-align: center;
    max-width: 520px;
  }
  .intro-logo {
    margin-bottom: 16px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
  }
  .intro-title {
    font-size: 18px;
    font-weight: 700;
    margin-bottom: 4px;
  }
  .intro-sub {
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 16px;
  }
  .intro-sub strong {
    color: var(--accent);
  }
  .intro-progress-bar {
    position: relative;
    width: 100%;
    height: 10px;
    border-radius: 999px;
    background: #020617;
    overflow: hidden;
    border: 1px solid #1f2937;
    box-shadow: inset 0 0 8px rgba(0,0,0,1);
  }
  .intro-progress-fill {
    position: absolute;
    inset: 0;
    width: 0%;
    border-radius: inherit;
    background: linear-gradient(90deg,#66c0f4,#1b95de,#66c0f4);
    background-size: 260% 100%;
    animation: shine 3.5s linear infinite;
  }
  .intro-progress-label {
    margin-top: 6px;
    font-size: 11px;
    color: var(--muted);
    display: flex;
    justify-content: space-between;
    gap: 8px;
  }
  .intro-progress-percent {
    font-variant-numeric: tabular-nums;
    color: var(--accent);
  }
  .intro-progress-message {
    text-align: right;
  }

  /* ------------ Completion popup ------------ */
  .completion-overlay {
    position: absolute;
    inset: 0;
    background: radial-gradient(circle at center, rgba(3,7,18,0.95) 0, rgba(3,7,18,0.99) 50%);
    display: none;
    align-items: center;
    justify-content: center;
    z-index: 900;
    opacity: 0;
    transition: opacity 0.35s ease-out;
  }
  .completion-dialog {
    width: 520px;
    max-width: 520px;
    border-radius: 22px;
    background: radial-gradient(circle at top left, #111827 0, #020617 60%);
    border: 1px solid rgba(102,192,244,0.35);
    box-shadow:
      0 30px 70px rgba(0,0,0,0.95),
      0 0 0 1px rgba(15,23,42,0.9);
    padding: 20px 22px 18px;
    position: relative;
    color: var(--text);
  }
  .completion-title-row {
    display: flex;
    align-items: center;
    gap: 12px;
    margin-bottom: 10px;
  }
  .completion-icon-pill {
    width: 32px;
    height: 32px;
    border-radius: 12px;
    background: radial-gradient(circle at 20% 20%, #1b2838 0, #2a475e 45%, #0b141d 100%);
    display: flex;
    align-items: center;
    justify-content: center;
    box-shadow:
      0 0 0 1px rgba(15,23,42,1),
      0 0 24px rgba(22,163,74,0.9);
  }
  .completion-icon-check {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    border: 2px solid #22c55e;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 12px;
    color: #22c55e;
  }
  .completion-title-text {
    font-size: 17px;
    font-weight: 700;
  }
  .completion-subtitle {
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 10px;
  }
  .completion-subtitle strong {
    color: var(--accent);
  }
  .completion-body {
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 16px;
  }
  .completion-body ul {
    margin: 6px 0 0 18px;
    padding: 0;
  }
  .completion-body li {
    margin-bottom: 4px;
  }
  .completion-body a {
    color: var(--accent);
    text-decoration: none;
  }
  .completion-body a:hover {
    text-decoration: underline;
  }
  .completion-footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  .completion-btn-primary {
    padding: 8px 14px;
    border-radius: 999px;
    background: linear-gradient(135deg,#22c55e,#15803d);
    color: #020617;
    font-size: 12px;
    font-weight: 600;
    border: none;
    cursor: pointer;
    box-shadow:
      0 10px 24px rgba(0,0,0,0.9),
      0 0 0 1px rgba(22,163,74,0.8);
  }
  .completion-btn-secondary {
    padding: 8px 12px;
    border-radius: 999px;
    background: radial-gradient(circle at 0 0,#020617 0,#020617 70%,#000000 100%);
    border: 1px solid #27394a;
    color: var(--muted);
    font-size: 12px;
    cursor: pointer;
  }
</style>
</head>
<body>
<div class="app-root">
  <div class="card">

    <!-- Intro overlay -->
    <div class="intro-overlay" id="intro-overlay">
      <div class="intro-inner">
        <div class="intro-logo">
          <div class="logo-pill">
            <div class="logo-pulse"></div>
            <img src="__LOGO_URL__" alt="EA SPORTS FC 26 Logo" class="logo-img">
          </div>
        </div>
        <div class="intro-title">Preparing game tools…</div>
        <div class="intro-sub">
          Downloading required files from Barry's GameStore GitHub before starting the downloader.
          <br>
          <strong>Please keep this window open.</strong>
        </div>
        <div class="intro-progress-bar">
          <div class="intro-progress-fill" id="intro-progress-fill"></div>
        </div>
        <div class="intro-progress-label">
          <span class="intro-progress-percent" id="intro-progress-percent">0%</span>
          <span class="intro-progress-message" id="intro-progress-message">Starting bootstrap…</span>
        </div>
      </div>
    </div>

    <!-- Completion popup -->
    <div class="completion-overlay" id="completion-overlay">
      <div class="completion-dialog">
        <div class="completion-title-row">
          <div class="completion-icon-pill">
            <div class="completion-icon-check">✔</div>
          </div>
          <div>
            <div class="completion-title-text">Game download completed</div>
            <div class="completion-subtitle">
              EA SPORTS FC 26 is ready to play.
              <strong>A desktop shortcut has been created for you.</strong>
            </div>
          </div>
        </div>
        <div class="completion-body">
          <p>What’s done:</p>
          <ul>
            <li>Game content fully downloaded and extracted.</li>
            <li><strong>“EA SPORTS FC 26” shortcut</strong> created on your Desktop (launches <code>FC26.exe</code>).</li>
          </ul>
          <p>
            <strong>Next step:</strong><br>
            Please send your <strong>Denuvo ticket</strong> to the Discord admin to complete your activation.
          </p>
          <p>
            You can join our Discord server here:<br>
            <a href="https://discord.com/invite/cKKM2hyd4d" target="_blank">
              https://discord.com/invite/cKKM2hyd4d
            </a>
          </p>
        </div>
        <div class="completion-footer">
          <button id="btn-open-discord" class="completion-btn-secondary" type="button">
            Open Discord
          </button>
          <button id="btn-completion-ok" class="completion-btn-primary" type="button">
            OK, got it
          </button>
        </div>
      </div>
    </div>

    <!-- Main header + app -->
    <div class="card-header">
      <div class="logo-pill">
        <div class="logo-pulse"></div>
        <img src="__LOGO_URL__" alt="EA SPORTS FC 26 Logo" class="logo-img">
      </div>
      <div class="title-block">
        <div class="title-row">
          <div class="title-main">EA SPORTS FC 26</div>
          <div class="title-tagline">• Download Manager</div>
        </div>
        <div class="title-sub">
          Download the game data with live progress and logs.
        </div>
      </div>
      <div class="badge">
        STATUS: <span id="status-badge-label">IDLE</span>
      </div>
    </div>

    <div class="card-body">
      <div class="panel">
        <div class="section-title">
          <div class="section-title-dot"></div>
          Download Progress
        </div>
        <div class="status-row">
          <div class="status-text">
            <span id="status-text-prefix">Ready.</span>
            <strong id="status-text-main">Click “Start download” to begin.</strong>
          </div>
          <div id="status-chip" class="status-chip" data-state="idle">
            <div class="status-dot"></div>
            <span id="status-chip-label">Idle</span>
          </div>
        </div>

        <div class="progress-bar">
          <div class="progress-inner">
            <div id="progress-fill" class="progress-fill"></div>
            <div class="progress-stripes"></div>
          </div>
        </div>

        <div class="progress-footer">
          <div class="progress-percent" id="progress-percent">0%</div>
          <div class="progress-note" id="progress-note">
            Waiting to start. Please do not close this window while downloading.
          </div>
        </div>

        <div class="controls">
          <button id="btn-start" class="btn-primary" type="button" data-working="false">
            <div class="btn-primary-icon">▶</div>
            <span id="btn-start-label">Start download</span>
          </button>
          <button id="btn-open-folder" class="btn-secondary" type="button">
            <div class="btn-secondary-icon"></div>
            Open game folder after completion
          </button>
        </div>

        <!-- Combined download log under progress -->
        <div class="log-panel-content">
          <div class="section-title" style="margin-top: 6px;">
            <div class="section-title-dot"></div>
            Download Log
          </div>
          <div class="log-header">
            <div class="log-hint" id="log-hint">Live download output.</div>
            <div style="font-size:10px; color:var(--muted);">
              Last <span id="log-count">0</span> lines shown
            </div>
          </div>

          <div class="log-summary">
            <div class="log-summary-item">
              <div class="log-summary-label">Result</div>
              <div class="log-summary-value" id="log-summary-result" data-state="progress">Waiting…</div>
            </div>
            <div class="log-summary-item">
              <div class="log-summary-label">Folder</div>
              <div class="log-summary-value" id="log-summary-folder">–</div>
            </div>
            <div class="log-summary-item">
              <div class="log-summary-label">Depots</div>
              <div class="log-summary-value" id="log-summary-depots">–</div>
            </div>
          </div>

          <div id="log-box" class="log-box"></div>
        </div>
      </div>
    </div>

    <div class="card-footer">
      <div class="footer-left">
        <div class="footer-pill">
          Do not close this window while the download is running.
        </div>
        <div class="footer-pill">
          Game size is large – make sure you have enough storage space.
        </div>
      </div>
      <div class="footer-right">
        Created for a smoother FC 26 download experience ✨
      </div>
    </div>
  </div>
</div>

<script>
  /* Main UI refs */
  const btnStart      = document.getElementById('btn-start');
  const btnStartLabel = document.getElementById('btn-start-label');
  const btnOpenFolder = document.getElementById('btn-open-folder');
  const progressFill  = document.getElementById('progress-fill');
  const progressPercent = document.getElementById('progress-percent');
  const progressNote  = document.getElementById('progress-note');
  const statusChip    = document.getElementById('status-chip');
  const statusChipLabel = document.getElementById('status-chip-label');
  const statusBadgeLabel = document.getElementById('status-badge-label');
  const statusTextPrefix = document.getElementById('status-text-prefix');
  const statusTextMain   = document.getElementById('status-text-main');
  const logBox        = document.getElementById('log-box');
  const logCount      = document.getElementById('log-count');
  const logHint       = document.getElementById('log-hint');

  const logSummaryResult = document.getElementById('log-summary-result');
  const logSummaryFolder = document.getElementById('log-summary-folder');
  const logSummaryDepots = document.getElementById('log-summary-depots');

  /* Intro overlay refs */
  const introOverlay  = document.getElementById('intro-overlay');
  const introFill     = document.getElementById('intro-progress-fill');
  const introPercent  = document.getElementById('intro-progress-percent');
  const introMessage  = document.getElementById('intro-progress-message');

  /* Completion popup refs */
  const completionOverlay = document.getElementById('completion-overlay');
  const btnCompletionOk   = document.getElementById('btn-completion-ok');
  const btnOpenDiscord    = document.getElementById('btn-open-discord');

  let lastStatus = "idle";
  let introFinished = false;
  let completionShown = false;

  function setStatusUI(state, extra) {
    // state: idle | running | done | error
    statusChip.dataset.state = state;
    let label = "";
    let badge = "";
    let prefix = "";
    let main = "";

    if (state === "idle") {
      label = "Idle";
      badge = "IDLE";
      prefix = "Ready.";
      main = "Click “Start download” to begin.";
    } else if (state === "running") {
      label = "Downloading...";
      badge = "DOWNLOADING…";
      prefix = "Working.";
      main = extra || "The download is currently in progress.";
    } else if (state === "done") {
      label = "Completed";
      badge = "COMPLETED";
      prefix = "Done.";
      main = extra || "All files processed. You can close this window.";
    } else if (state === "error") {
      label = "Error";
      badge = "ERROR";
      prefix = "Something went wrong.";
      main = extra || "Check the log for details.";
    }

    statusChipLabel.textContent = label;
    statusBadgeLabel.textContent = badge;
    statusTextPrefix.textContent = prefix + " ";
    statusTextMain.textContent = main;
  }

  function updateLogSummary(lines) {
    if (!Array.isArray(lines) || lines.length === 0) {
      logSummaryResult.textContent = "Waiting…";
      logSummaryResult.dataset.state = "progress";
      logSummaryFolder.textContent = "–";
      logSummaryDepots.textContent = "–";
      return;
    }

    const text = lines.join("\\n");
    let resultState = "progress";
    let resultLabel = "In progress…";

    if (/download completed/i.test(text) || /Post-download setup finished successfully/i.test(text)) {
      resultState = "ok";
      resultLabel = "Download & setup completed successfully";
    } else if (/error/i.test(text) || /failed/i.test(text)) {
      resultState = "error";
      resultLabel = "Download encountered errors";
    }

    logSummaryResult.textContent = resultLabel;
    logSummaryResult.dataset.state = resultState;

    const folderMatch = /All files downloaded to:\\s*"(.*?)"/i.exec(text);
    logSummaryFolder.textContent = folderMatch ? folderMatch[1] : "–";

    const depotMatch = /Total depots processed:\\s*(\\d+)/i.exec(text);
    logSummaryDepots.textContent = depotMatch ? depotMatch[1] : "–";
  }

  async function startDownload() {
    if (!window.pywebview || !pywebview.api) {
      alert("pywebview API not available yet.");
      return;
    }

    btnStart.disabled = true;
    btnStart.dataset.working = "true";
    btnStartLabel.textContent = "Working...";
    progressNote.textContent = "Starting the download. Please wait…";
    setStatusUI("running");

    try {
      const res = await pywebview.api.start_download();
      if (!res || !res.ok) {
        btnStart.disabled = false;
        btnStart.dataset.working = "false";
        btnStartLabel.textContent = "Start download";
        setStatusUI("error", (res && res.message) || "Unable to start download.");
        progressNote.textContent = "Failed to start. Check the log for more info.";
      }
    } catch (e) {
      console.error(e);
      btnStart.disabled = false;
      btnStart.dataset.working = "false";
      btnStartLabel.textContent = "Start download";
      setStatusUI("error", "Exception while starting download. See log.");
      progressNote.textContent = "Error occurred. See log.";
    }
  }

  function showCompletionPopup() {
    if (completionShown) return;
    completionShown = true;
    completionOverlay.style.display = "flex";
    requestAnimationFrame(() => {
      completionOverlay.style.opacity = "1";
    });
  }

  function hideCompletionPopup() {
    completionOverlay.style.opacity = "0";
    setTimeout(() => {
      completionOverlay.style.display = "none";
    }, 300);
  }

  async function pollStatusLoop() {
    if (window.pywebview && pywebview.api && pywebview.api.get_status) {
      try {
        const st = await pywebview.api.get_status();
        if (st) {
          const p = Math.max(0, Math.min(100, st.progress || 0));
          progressFill.style.width = p + "%";
          progressPercent.textContent = p.toFixed(0) + "%";

          const status = st.status || "idle";

          if (status !== lastStatus) {
            if (status === "idle") {
              setStatusUI("idle");
              btnStart.disabled = false;
              btnStart.dataset.working = "false";
              btnStartLabel.textContent = "Start download";

            } else if (status === "running") {
              setStatusUI("running");
              btnStart.disabled = true;
              btnStart.dataset.working = "true";
              btnStartLabel.textContent = "Working...";

            } else if (status === "completed") {
              setStatusUI("done");
              progressNote.textContent = "Download and post-setup completed successfully.";
              btnStart.dataset.working = "false";
              btnStartLabel.textContent = "Download finished";
              btnStart.disabled = true;

              // Show the big completion popup once
              showCompletionPopup();

            } else if (status === "error") {
              setStatusUI("error");
              progressNote.textContent = "An error occurred. See log for details.";
              btnStart.dataset.working = "false";
              btnStart.disabled = false;
              btnStartLabel.textContent = "Retry";
            }

            lastStatus = status;
          }

          if (Array.isArray(st.log)) {
            logBox.textContent = st.log.join("\\n");
            logBox.scrollTop = logBox.scrollHeight;
            logCount.textContent = st.log.length;
            if (st.log.length > 0) {
              logHint.textContent = "Live download output:";
            }
            updateLogSummary(st.log);
          }
        }
      } catch (e) {
        console.error("pollStatusLoop error", e);
      }
    }

    setTimeout(pollStatusLoop, 600);
  }

  async function openFolder() {
    if (window.pywebview && pywebview.api && pywebview.api.open_game_folder) {
      try {
        await pywebview.api.open_game_folder();
      } catch (e) {
        console.error(e);
      }
    }
  }

  /* ---------- Bootstrap (intro) ---------- */

  function applyIntroState(st) {
    if (!st) return;
    const p = Math.max(0, Math.min(100, st.progress || 0));
    introFill.style.width = p + "%";
    introPercent.textContent = p.toFixed(0) + "%";
    introMessage.textContent = st.message || "";

    if (!introFinished && (st.status === "done" || st.status === "error")) {
      introFinished = true;
      // fade out overlay
      introOverlay.style.opacity = "0";
      setTimeout(() => {
        introOverlay.style.display = "none";
      }, 400);
    }
  }

  async function pollBootstrapLoop() {
    if (window.pywebview && pywebview.api && pywebview.api.get_bootstrap_status) {
      try {
        const st = await pywebview.api.get_bootstrap_status();
        applyIntroState(st);
      } catch (e) {
        console.error("pollBootstrapLoop error", e);
      }
    }
    if (!introFinished) {
      setTimeout(pollBootstrapLoop, 600);
    }
  }

  async function startBootstrap() {
    try {
      if (window.pywebview && pywebview.api && pywebview.api.start_bootstrap) {
        await pywebview.api.start_bootstrap();
      }
    } catch (e) {
      console.error("startBootstrap error", e);
    }
    pollBootstrapLoop();
  }

  function waitForAPIAndInit() {
    if (window.pywebview && pywebview.api) {
      btnStart.addEventListener("click", startDownload);
      btnOpenFolder.addEventListener("click", openFolder);

      btnCompletionOk.addEventListener("click", hideCompletionPopup);
      btnOpenDiscord.addEventListener("click", async () => {
        try {
          if (window.pywebview && pywebview.api && pywebview.api.open_discord) {
            await pywebview.api.open_discord();
          } else {
            window.open("https://discord.com/invite/cKKM2hyd4d", "_blank");
          }
        } catch (e) {
          console.error("Failed to open Discord", e);
        }
      });

      pollStatusLoop();
      startBootstrap();
    } else {
      setTimeout(waitForAPIAndInit, 100);
    }
  }

  document.addEventListener("DOMContentLoaded", waitForAPIAndInit);
</script>
</body>
</html>
"""

# ----------------- HTML logo injection -----------------


def _fallback_logo_data_uri():
    svg = """
    <svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>
      <rect width='64' height='64' rx='12' ry='12' fill='#171a21'/>
      <text x='50%' y='52%' text-anchor='middle' fill='#66c0f4'
            font-size='20' font-family='Segoe UI, sans-serif' font-weight='700'>
        FC
      </text>
    </svg>
    """
    return "data:image/svg+xml;utf8," + urllib.parse.quote(svg.strip())


def build_html():
    """Load fc26_logo.png, embed as data URL, and inject into HTML."""
    base_dir = get_run_dir()
    logo_path = os.path.join(base_dir, "fc26_logo.png")

    if os.path.exists(logo_path):
        try:
            with open(logo_path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
            logo_url = f"data:image/png;base64,{b64}"
        except Exception:
            logo_url = _fallback_logo_data_uri()
    else:
        logo_url = _fallback_logo_data_uri()

    return HTML_RAW.replace("__LOGO_URL__", logo_url)


# ----------------- GitHub download helpers -----------------


def _github_contents_url(path: str) -> str:
    encoded = urllib.parse.quote(path)
    return f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/contents/{encoded}?ref={GITHUB_BRANCH}"


def download_github_file(remote_path: str, dest_path: str, log_func=None):
    """
    Download a single file from Barry-sGameStore/FC26 using GitHub contents API.
    """
    headers = {
        "User-Agent": "BarryGameStore-FC26-Bootstrap",
        "Accept": "application/vnd.github.v3+json",
    }
    url = _github_contents_url(remote_path)
    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    info = resp.json()
    download_url = info.get("download_url")
    if not download_url:
        raise RuntimeError(f"No download_url for {remote_path}")

    if log_func:
        log_func(f"Downloading {remote_path} ...")

    r = requests.get(download_url, headers=headers, timeout=60)
    r.raise_for_status()
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with open(dest_path, "wb") as f:
        f.write(r.content)


def download_github_folder(folder_path: str, dest_dir: str, log_func=None):
    """
    Recursively download a folder from Barry-sGameStore/FC26 via /contents API.
    """
    headers = {
        "User-Agent": "BarryGameStore-FC26-Bootstrap",
        "Accept": "application/vnd.github.v3+json",
    }

    def log(msg):
        if log_func:
            log_func(msg)

    def recurse(path, dest):
        url = _github_contents_url(path)
        resp = requests.get(url, headers=headers, timeout=30)
        resp.raise_for_status()
        items = resp.json()

        if not isinstance(items, list):
            return

        for item in items:
            item_type = item.get("type")
            name = item.get("name")
            item_path = item.get("path")

            if item_type == "file":
                file_url = item.get("download_url")
                if not file_url:
                    continue
                log(f"Downloading {item_path} ...")
                r = requests.get(file_url, headers=headers, timeout=60)
                r.raise_for_status()
                out_path = os.path.join(dest, name)
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                with open(out_path, "wb") as f:
                    f.write(r.content)
            elif item_type == "dir":
                new_dest = os.path.join(dest, name)
                os.makedirs(new_dest, exist_ok=True)
                recurse(item_path, new_dest)

    os.makedirs(dest_dir, exist_ok=True)
    recurse(folder_path, dest_dir)


def download_from_raw_repo(
    owner: str, repo: str, branch: str, remote_path: str, dest_path: str, log_func=None
):
    """
    Simple helper to download a file from raw.githubusercontent.com for arbitrary repo/branch.
    """
    parts = remote_path.split("/")
    encoded_path = "/".join(urllib.parse.quote(p) for p in parts)
    url = f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{encoded_path}"

    if log_func:
        log_func(f"Downloading {remote_path} from {owner}/{repo}@{branch} ...")

    headers = {
        "User-Agent": "BarryGameStore-FC26-PostStep",
    }
    r = requests.get(url, headers=headers, timeout=120)
    r.raise_for_status()
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with open(dest_path, "wb") as f:
        f.write(r.content)


# ----------------- Backend API -----------------


class AppAPI:
    """
    Exposed to JS via pywebview.api.
    Handles:
      - bootstrap GitHub download (intro overlay)
      - integrated DepotDownloader pipeline (no .bat)
      - post-download step: UnRAR + Foosball26 parts + cleanup + shortcut
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._status = "idle"  # idle | running | completed | error
        self._progress = 0.0
        self._log_lines = []
        self._worker_thread = None

        self._bootstrap = {
            "status": "idle",  # idle | running | done | error
            "progress": 0.0,
            "message": "Waiting to start…",
        }

        # Persistent folder where the EXE/script lives
        self._app_dir = get_app_dir()

        # We still download this in bootstrap for reference, but we DO NOT EXECUTE it anymore
        self._script_path = os.path.join(self._app_dir, "download.bat")

        self._game_folder_name = "EA SPORTS FC 26"

    # ---------- Util ----------

    def _append_log(self, line: str):
        with self._lock:
            self._log_lines.append(line)
            if len(self._log_lines) > 1000:
                self._log_lines = self._log_lines[-800:]

    def _set_bootstrap(self, *, status=None, progress=None, message=None):
        with self._lock:
            if status is not None:
                self._bootstrap["status"] = status
            if progress is not None:
                self._bootstrap["progress"] = float(progress)
            if message is not None:
                self._bootstrap["message"] = message

    def _advance_progress(self, delta: float):
        """Increment progress by delta, capped at 99 during internal stages."""
        with self._lock:
            new_val = float(self._progress) + float(delta)
            if new_val > 99.0:
                new_val = 99.0
            self._progress = new_val

    def _popen_no_window(self, *args, **kwargs):
        """
        Wrapper around subprocess.Popen that hides the console window on Windows.
        """
        if sys.platform.startswith("win"):
            si = subprocess.STARTUPINFO()
            si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            cf = kwargs.get("creationflags", 0)
            cf |= subprocess.CREATE_NO_WINDOW
            kwargs["startupinfo"] = si
            kwargs["creationflags"] = cf

        return subprocess.Popen(*args, **kwargs)

    # ---------- Bootstrap API ----------

    def start_bootstrap(self):
        with self._lock:
            if self._bootstrap["status"] == "running":
                return {"ok": False, "message": "Bootstrap already running."}
            self._bootstrap.update(status="running", progress=0.0, message="Starting bootstrap…")

        t = threading.Thread(target=self._run_bootstrap, daemon=True)
        t.start()
        return {"ok": True}

    def get_bootstrap_status(self):
        with self._lock:
            return dict(self._bootstrap)

    def _run_bootstrap(self):
        base_dir = self._app_dir

        try:
            # Step 1: download/update download.bat (for reference – not executed)
            self._set_bootstrap(progress=5, message="Updating download tool…")
            download_github_file(GITHUB_DOWNLOAD_BAT_PATH, self._script_path, log_func=self._append_log)
            self._set_bootstrap(progress=20, message="Download tool updated.")

            # Step 2: DepotDownloaderMod
            self._set_bootstrap(progress=25, message="Updating DepotDownloaderMod from GitHub…")
            remote, local = BOOTSTRAP_FOLDERS[0]
            dest_dir = os.path.join(base_dir, local)
            shutil.rmtree(dest_dir, ignore_errors=True)
            download_github_folder(remote, dest_dir, log_func=self._append_log)
            self._set_bootstrap(progress=60, message="DepotDownloaderMod updated.")

            # Step 3: manifests & keys
            self._set_bootstrap(progress=65, message="Updating manifests & keys from GitHub…")
            remote2, local2 = BOOTSTRAP_FOLDERS[1]
            dest_dir2 = os.path.join(base_dir, local2)
            shutil.rmtree(dest_dir2, ignore_errors=True)
            download_github_folder(remote2, dest_dir2, log_func=self._append_log)
            self._set_bootstrap(progress=100, status="done", message="Bootstrap complete. Ready.")
        except Exception as e:
            self._append_log(f"BOOTSTRAP ERROR: {e}")
            self._set_bootstrap(status="error", message=f"Bootstrap failed: {e}")

    # ---------- Main status / control API ----------

    def start_download(self):
        with self._lock:
            if self._status == "running":
                return {"ok": False, "message": "Download already in progress."}
            self._status = "running"
            self._progress = 0.0
            self._log_lines = []

        t = threading.Thread(target=self._run_worker, daemon=True)
        self._worker_thread = t
        t.start()
        return {"ok": True}

    def get_status(self):
        with self._lock:
            return {
                "status": self._status,
                "progress": float(self._progress),
                "log": list(self._log_lines),
            }

    def open_game_folder(self):
        base_dir = self._app_dir
        folder_path = os.path.join(base_dir, self._game_folder_name)
        if not os.path.isdir(folder_path):
            folder_path = base_dir

        if sys.platform.startswith("win"):
            os.startfile(folder_path)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", folder_path])
        else:
            subprocess.Popen(["xdg-open", folder_path])
        return {"ok": True}

    def open_discord(self):
        """
        Open the Discord invite link in the user's default browser.
        """
        try:
            webbrowser.open(DISCORD_INVITE)
            self._append_log(f"Opened Discord invite: {DISCORD_INVITE}")
            return {"ok": True}
        except Exception as e:
            self._append_log(f"ERROR: Failed to open Discord: {e}")
            return {"ok": False, "message": str(e)}

    # ---------- DepotDownloader integration (no .bat) ----------

    def _get_depotdownloader_context(self):
        """
        Resolve DepotDownloader paths and key file from our app folder.
        """
        base_dir = self._app_dir

        dd_exe = os.path.join(base_dir, "DepotDownloaderMod", "DepotDownloadermod.exe")
        if not os.path.isfile(dd_exe):
            raise FileNotFoundError(f"DepotDownloadermod.exe not found at: {dd_exe}")

        manifests_dir = os.path.join(base_dir, "EA SPORTS FC 26 Manifests and Keys")
        if not os.path.isdir(manifests_dir):
            raise FileNotFoundError(f"Manifests & keys folder not found at: {manifests_dir}")

        # discover manifest files
        manifest_files = [
            f for f in os.listdir(manifests_dir)
            if f.lower().endswith(".manifest")
        ]
        if not manifest_files:
            raise FileNotFoundError("No .manifest files found in the manifests folder.")

        manifest_files.sort()  # stable order for progress

        # pick key file – prefer "3405690.key" if present
        key_candidates = [
            f for f in os.listdir(manifests_dir)
            if f.lower().endswith((".key", ".txt"))
        ]
        if not key_candidates:
            raise FileNotFoundError("No depot key (.key or .txt) files found in the manifests folder.")

        preferred = None
        for k in key_candidates:
            if "3405690" in k:
                preferred = k
                break
        if preferred is None:
            key_candidates.sort()
            preferred = key_candidates[0]

        keys_path = os.path.join(manifests_dir, preferred)

        self._append_log(f"Using DepotDownloader at: {dd_exe}")
        self._append_log(f"Using manifests from: {manifests_dir}")
        self._append_log(f"Using depot key file: {preferred}")

        return dd_exe, manifests_dir, keys_path, manifest_files

    def _run_single_depot(
        self,
        dd_exe,
        app_id,
        depot_id,
        manifest_id,
        manifest_path,
        keys_path,
        game_dir,
        depot_index,
        depot_total,
    ):
        """
        Run DepotDownloadermod.exe for a single depot and stream output to log + progress.
        """
        self._append_log(f"[{depot_index}/{depot_total}] Downloading depot {depot_id}...")
        rel_manifest = os.path.basename(manifest_path)

        cmd = [
            dd_exe,
            "-app",
            str(app_id),
            "-depot",
            str(depot_id),
            "-manifest",
            str(manifest_id),
            "-manifestfile",
            manifest_path,
            "-depotkeys",
            keys_path,
            "-dir",
            game_dir,
            "-max-downloads",
            "256",
            "-verify-all",
        ]

        # Each depot contributes equally to 80% of global progress
        depot_base = (depot_index - 1) * (80.0 / depot_total)
        depot_span = 80.0 / depot_total

        proc = self._popen_no_window(
            cmd,
            cwd=self._app_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True,
        )

        for raw in proc.stdout:
            line = raw.rstrip("\r\n")
            if not line:
                continue

            self._append_log(f"[{depot_id}] {line}")

            # look for "xx%" in the line and map to global progress
            m = re.search(r"(\d{1,3})\s*%", line)
            if m:
                try:
                    local_pct = int(m.group(1))
                    if 0 <= local_pct <= 100:
                        g = depot_base + (local_pct / 100.0) * depot_span
                        with self._lock:
                            if g > self._progress:
                                self._progress = g
                except ValueError:
                    pass

        proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(
                f"Depot {depot_id} failed with exit code {proc.returncode} "
                f"(manifest {rel_manifest})."
            )

        # Make sure we finish this depot’s slice
        with self._lock:
            if self._progress < depot_base + depot_span:
                self._progress = depot_base + depot_span

        self._append_log(f"Depot {depot_id} completed.")

    def _run_main_download_pipeline(self):
        """
        Pure Python replacement for download.bat.
        Uses DepotDownloadermod.exe directly for each manifest/depot.
        """
        base_dir = self._app_dir
        game_dir = os.path.join(base_dir, self._game_folder_name)
        os.makedirs(game_dir, exist_ok=True)

        app_id = 3405690  # EA SPORTS FC 26

        dd_exe, manifests_dir, keys_path, manifest_files = self._get_depotdownloader_context()
        total = len(manifest_files)

        self._append_log("==========================================================")
        self._append_log("Starting main DepotDownloader pipeline (no batch file)...")
        self._append_log(f"App ID: {app_id}, total depots: {total}")
        self._append_log("==========================================================")

        # Ensure we leave a bit of bar for bootstrap
        with self._lock:
            if self._progress < 5.0:
                self._progress = 5.0

        processed_depots = 0

        for idx, manifest_name in enumerate(manifest_files, start=1):
            manifest_path = os.path.join(manifests_dir, manifest_name)

            # Expect filename: <depotid>_<manifestid>.manifest
            m = re.match(r"(\d+)_([0-9]+)", manifest_name)
            if not m:
                self._append_log(
                    f"WARNING: Could not read depot/manifest id from '{manifest_name}', skipping."
                )
                continue

            depot_id = int(m.group(1))
            manifest_id = int(m.group(2))

            self._run_single_depot(
                dd_exe,
                app_id,
                depot_id,
                manifest_id,
                manifest_path,
                keys_path,
                game_dir,
                idx,
                total,
            )
            processed_depots += 1

        # after all depots, clamp to at least 80% before post steps
        with self._lock:
            if self._progress < 80.0:
                self._progress = 80.0

        self._append_log("All depot downloads finished.")
        self._append_log(f"All files downloaded to: \"{self._game_folder_name}\" folder")
        self._append_log(f"Total depots processed: {processed_depots}")
        self._append_log("Proceeding with post-download tasks (extraction, cleanup, shortcut)...")

    # ---------- Post-download: UnRAR + Foosball26 parts + shortcut ----------

    def _create_desktop_shortcut(self, target_path: str):
        """
        Create EA SPORTS FC 26.lnk on the Desktop pointing to target_path (Windows-only).
        """
        if not sys.platform.startswith("win"):
            self._append_log("Skipping desktop shortcut creation (non-Windows platform).")
            return

        if not os.path.exists(target_path):
            self._append_log(f"FC26.exe not found at '{target_path}', skipping shortcut.")
            return

        desktop_dir = os.path.join(os.path.expanduser("~"), "Desktop")
        try:
            os.makedirs(desktop_dir, exist_ok=True)
        except Exception:
            pass

        shortcut_path = os.path.join(desktop_dir, "EA SPORTS FC 26.lnk")

        ps_cmd = (
            "$WshShell = New-Object -ComObject WScript.Shell; "
            f"$Shortcut = $WshShell.CreateShortcut('{shortcut_path}'); "
            f"$Shortcut.TargetPath = '{target_path}'; "
            f"$Shortcut.WorkingDirectory = '{os.path.dirname(target_path)}'; "
            f"$Shortcut.IconLocation = '{target_path},0'; "
            "$Shortcut.Save();"
        )

        try:
            result = subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_cmd],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if result.stdout.strip():
                self._append_log(f"[SHORTCUT] {result.stdout.strip()}")
            if result.stderr.strip():
                self._append_log(f"[SHORTCUT-ERR] {result.stderr.strip()}")
            self._append_log(f"Desktop shortcut created: {shortcut_path}")
        except Exception as e:
            self._append_log(f"WARNING: Could not create desktop shortcut: {e}")

    def _run_post_download_tasks(self):
        """
        After main pipeline completes successfully:
          1) Download UnRAR.exe from Barry-sGameStore/FC26
          2) Download 5 Foosball26.partX.rar from fussboll/Foosball26
          3) Extract Foosball26.part1.rar into EA SPORTS FC 26 folder
          4) Delete Foosball26.partX.rar files
          5) Create Desktop shortcut to FC26.exe
        """
        base_dir = self._app_dir

        # 1) Ensure UnRAR.exe exists
        unrar_path = os.path.join(base_dir, "UnRAR.exe")
        self._append_log("Downloading UnRAR.exe from Barry-sGameStore...")
        download_github_file(GITHUB_UNRAR_PATH, unrar_path, log_func=self._append_log)
        self._advance_progress(2.5)

        # 2) Download 5 rar parts into base_dir
        for fname in FOOS_PART_FILES:
            dest = os.path.join(base_dir, fname)
            self._append_log(f"Downloading {fname} from fussboll/Foosball26...")
            download_from_raw_repo(
                FUSS_OWNER,
                FUSS_REPO,
                FUSS_BRANCH,
                fname,
                dest,
                log_func=self._append_log,
            )
            self._advance_progress(3.0)

        # 3) Extract Foosball26.part1.rar into EA SPORTS FC 26 folder
        game_folder = os.path.join(base_dir, self._game_folder_name)
        os.makedirs(game_folder, exist_ok=True)

        part1_name = FOOS_PART_FILES[0]
        part1_path = os.path.join(base_dir, part1_name)

        if not os.path.exists(unrar_path):
            raise RuntimeError("UnRAR.exe missing after download.")
        if not os.path.exists(part1_path):
            raise RuntimeError(f"{part1_name} missing after download.")

        self._append_log(f"Extracting {part1_name} into '{game_folder}' ...")

        proc = self._popen_no_window(
            [unrar_path, "x", "-y", part1_name, game_folder],
            cwd=base_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True,
        )

        for raw_line in proc.stdout:
            line = raw_line.rstrip("\r\n")
            if line:
                self._append_log(f"[UNRAR] {line}")

        proc.wait()

        if proc.returncode != 0:
            raise RuntimeError(f"UnRAR exited with code {proc.returncode}.")

        self._advance_progress(5.0)

        # 4) Clean up rar parts
        self._append_log("Cleaning up Foosball26 part files...")
        for fname in FOOS_PART_FILES:
            path = os.path.join(base_dir, fname)
            if os.path.exists(path):
                try:
                    os.remove(path)
                    self._append_log(f"Deleted {fname}")
                except Exception as e:
                    self._append_log(f"WARNING: Could not delete {fname}: {e}")
        self._advance_progress(2.0)

        # 5) Create Desktop shortcut for FC26.exe
        fc_exe_path = os.path.join(game_folder, "FC26.exe")
        self._append_log("Creating desktop shortcut for FC26.exe (if possible)...")
        self._create_desktop_shortcut(fc_exe_path)
        self._advance_progress(2.5)

    # ---------- Worker ----------

    def _run_worker(self):
        """
        Worker thread: run main DepotDownloader pipeline (no .bat),
        then run post-download tasks (Foosball26 parts, UnRAR, shortcut).
        """
        self._append_log("Launching download pipeline (integrated, no batch file)...")
        self._append_log("----------------------------------------------------------")

        try:
            self._run_main_download_pipeline()
        except Exception as e:
            self._append_log(f"ERROR during main download: {e}")
            with self._lock:
                self._status = "error"
            return

        # Main pipeline OK → run post-download steps
        try:
            self._run_post_download_tasks()
            with self._lock:
                self._progress = 100.0
                self._status = "completed"
            self._append_log("Post-download setup finished successfully.")
            self._append_log("DOWNLOAD COMPLETED!")
        except Exception as e:
            self._append_log(f"POST-DOWNLOAD ERROR: {e}")
            with self._lock:
                self._status = "error"


# ----------------- main -----------------


def main():
    api = AppAPI()
    html = build_html()
    window = webview.create_window(
        "EA SPORTS FC 26 - Download Manager",
        html=html,
        js_api=api,
        width=900,
        height=700,
        resizable=False,
    )
    # Let pywebview choose the best backend (no forced Qt)
    webview.start(debug=False)


if __name__ == "__main__":
    main()
