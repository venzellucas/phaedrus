const copyButton = document.querySelector("#copy-install");
const copyStatus = document.querySelector("#copy-status");
if (navigator.clipboard && window.isSecureContext) {
  copyButton.hidden = false;
  copyButton.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(
        document.querySelector("#install-commands").textContent,
      );
      copyButton.textContent = "Copied!";
      copyStatus.textContent = "Installation commands copied to clipboard.";
      setTimeout(() => {
        copyButton.textContent = "Copy commands";
      }, 2500);
    } catch {
      copyStatus.textContent =
        "Could not access the clipboard. Select and copy the commands below.";
      copyButton.textContent = "Select commands to copy";
    }
  });
}

const playButton = document.querySelector("#play-demo");
const demoText = document.querySelector("#demo-text");
const demoStatus = document.querySelector("#demo-status");
const recordingPreview = document.querySelector("#recording-preview");
const example = demoText.textContent.trim();
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
let finishTimer;
let playing = false;

function finishPreview(stopped = false) {
  clearTimeout(finishTimer);
  playing = false;
  recordingPreview.src = "media/listening.png";
  demoText.textContent = example;
  demoStatus.textContent = stopped ? "Preview stopped." : "Example complete. Text appears when dictation finishes.";
  playButton.textContent = "Play recording ↻";
}

playButton.hidden = false;
playButton.addEventListener("click", () => {
  if (playing) { finishPreview(true); return; }
  if (reducedMotion.matches) { finishPreview(); return; }
  playing = true;
  demoText.textContent = "";
  demoStatus.textContent = "Recording preview playing. No microphone is used.";
  playButton.textContent = "Stop preview";
  recordingPreview.src = "media/listening-live.gif";
  finishTimer = setTimeout(() => finishPreview(), 8000);
});
reducedMotion.addEventListener("change", () => {
  if (reducedMotion.matches && playing) finishPreview(true);
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden && playing) finishPreview(true);
});
