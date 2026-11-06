"""Check dashboard rendering in an isolated headless browser without a server."""

import os
from pathlib import Path
import re
import subprocess
import tempfile


root = Path(__file__).resolve().parent.parent
html = (root / "webui" / "index.html").read_text(encoding="utf-8-sig")
browser_candidates = [
    os.environ.get("MEMREDUCT_TEST_BROWSER", ""),
    str(Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"))
        / "Microsoft" / "Edge" / "Application" / "msedge.exe"),
    str(Path(os.environ.get("PROGRAMFILES", r"C:\Program Files"))
        / "Google" / "Chrome" / "Application" / "chrome.exe"),
]
browser = next((Path(path) for path in browser_candidates if path and Path(path).is_file()), None)
if browser is None:
    raise SystemExit("Edge or Chrome is required; set MEMREDUCT_TEST_BROWSER to its executable")

fixture = r"""
<script>
const attackSensor = '<svg onload="document.body.dataset.sensorXss=1"></svg>&"\'';
const attackDisk = '<svg onload="document.body.dataset.diskXss=1"></svg>&"\'';
renderTemp({sensors:[{id:'audit',kind:'other',name:attackSensor,c:33}],sources:{}});
renderDrive({drives:[{letter:'C:',label:attackDisk,freeGB:50,totalGB:100,usedPct:50}]});
setTimeout(() => {
  const sensor = document.querySelector('#tempList .tname');
  const row = document.querySelector('#tempList .trow');
  const disk = document.querySelector('#diskList .dlabel');
  const passed = !document.body.dataset.sensorXss && !document.body.dataset.diskXss &&
    sensor && sensor.textContent === attackSensor && row && row.title.startsWith(attackSensor) &&
    disk && disk.textContent === attackDisk;
  document.body.dataset.renderAudit = passed ? 'PASS' : 'FAIL';
}, 100);
</script>
"""
if "</body>" not in html:
    raise SystemExit("Dashboard body not found")

with tempfile.TemporaryDirectory(prefix="memreduct-render-test-") as temp:
    temp_path = Path(temp)
    page = temp_path / "index.html"
    page.write_text(html.replace("</body>", fixture + "</body>"), encoding="utf-8")
    result = subprocess.run(
        [str(browser), "--headless", "--disable-gpu", "--no-first-run",
         "--no-default-browser-check", "--disable-background-networking",
         "--disable-extensions", f"--user-data-dir={temp_path / 'profile'}",
         "--virtual-time-budget=1500", "--dump-dom", page.as_uri()],
        capture_output=True, encoding="utf-8", errors="replace", timeout=45,
    )
    if result.returncode != 0:
        raise SystemExit(f"Headless browser failed: exit={result.returncode}\n{result.stderr}")
    if 'data-render-audit="PASS"' not in result.stdout:
        status = re.search(r'data-render-audit="([^"]+)"', result.stdout)
        sensor_xss = 'data-sensor-xss="1"' in result.stdout
        disk_xss = 'data-disk-xss="1"' in result.stdout
        raise SystemExit("Dashboard failed to safely render sensor names and disk labels: "
                         f"status={status.group(1) if status else 'not executed'}, "
                         f"sensor_xss={sensor_xss}, disk_xss={disk_xss}")

print("PASS: dashboard renders sensor names and disk labels as text")
