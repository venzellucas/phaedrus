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
const demo = document.querySelector(".demo");
const demoText = document.querySelector("#demo-text");
const demoStatus = document.querySelector("#demo-status");
const example = demoText.textContent;
playButton.hidden = false;
playButton.addEventListener("click", () => {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    demoText.textContent = example;
    demoStatus.textContent = "Example complete.";
    return;
  }
  playButton.disabled = true;
  demo.classList.add("is-playing");
  demoStatus.textContent = "Listening…";
  demoText.textContent = "";
  let character = 0;
  const timer = setInterval(() => {
    demoText.textContent = example.slice(0, ++character);
    if (character >= example.length) {
      clearInterval(timer);
      demo.classList.remove("is-playing");
      demoStatus.textContent = "A thought, put into words.";
      playButton.disabled = false;
    }
  }, 48);
});
