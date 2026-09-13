"use strict";
const descriptions={city:"Code Atlas City view showing an invented Fieldnotes project as raised file tiles.",map:"Code Atlas Map view showing generated source, notes, tests, and artwork in a folder treemap.",source:"The native source reader displaying Camera.swift from the invented Fieldnotes project.",document:"The native document reader displaying the generated Field Guide Markdown file.",image:"The native image preview displaying generated geometric landscape artwork."};
document.querySelectorAll("[data-shot]").forEach(button=>button.addEventListener("click",()=>{
  const shot=button.dataset.shot;
  document.getElementById("app-screenshot").src="assets/"+shot+".png";
  document.getElementById("app-screenshot").alt=descriptions[shot];
  document.getElementById("screenshot-link").href="assets/"+shot+".png";
  document.querySelectorAll("[data-shot]").forEach(other=>{const selected=other===button;other.classList.toggle("active",selected);other.setAttribute("aria-pressed",String(selected));});
}));
document.getElementById("copy-command").addEventListener("click",async()=>{
  const status=document.getElementById("copy-status");
  try{await navigator.clipboard.writeText(document.getElementById("build-command").textContent);status.textContent="Copied";document.getElementById("copy-command").textContent="Copied ✓";}
  catch{const range=document.createRange();range.selectNodeContents(document.getElementById("build-command"));const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);status.textContent="Commands selected — copy to continue";}
});
