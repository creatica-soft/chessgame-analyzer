#!/usr/bin/env python3
"""Stages the App Store screenshot scenes in an iOS simulator and captures them.

    python3 -I tools/screenshots/stage.py --device "iPhone 18 Pro Max" [--scene game ...] [--wait-scale 1.5]
    python3 -I tools/screenshots/stage.py --upload      (the upload-ready copies, see below)

Needs the Debug simulator build in build/dd (xcodebuild ... -derivedDataPath build/dd build): the scenes
are set up by the app's debug launch arguments (-demoGame, -demoScan, -demoDiagram, -demoBoardFile,
-demoLiveFile). The real-board scenes use the clips of the wooden set (tools/training3/IMG_9285.MOV and
a frame of it in tools/work/live). Screenshots go to ~/Documents/ChessAnalyzer-Screenshots/<device>/.

--upload makes the copies App Store Connect takes: iPhone 6.3" (1206 x 2622, resized from the 6.9"
captures) and iPad 13" (2064 x 2752), RGB without alpha.
"""
import argparse, json, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.expanduser("~/Documents/ChessAnalyzer-Screenshots")
BUNDLE = "org.creatica.chess-analyzer"
APP = os.path.join(ROOT, "build/dd/Build/Products/Debug-iphonesimulator/ChessAnalyzer.app")
MOVIE = os.path.join(ROOT, "tools/training3/IMG_9285.MOV")
BOARD_PHOTO = os.path.join(ROOT, "tools/work/live/IMG_9285-015.jpg")

# name: (launch arguments, seconds to wait before the capture)
SCENES = {
    "1-game": (["-demoGame", "-demoSelect", "18"], 150),      # 9...b5, a mistake: the arrow shows the better move
    "2-line": (["-demoGame", "-demoSelect", "21", "-demoLine", "3"], 150),
    "3-diagram": (["-demoDiagram"], 25),
    "4-scan": (["-demoScan"], 25),
    "5-board": (["-demoBoardFile", BOARD_PHOTO], 25),
    # The live camera (-demoLiveFile MOVIE) settles within seconds in the simulator, too fast to catch
    # it reading, and its result looks like 5-board: left out.
}


def run(*cmd, check=True, timeout=300):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, timeout=timeout).stdout.strip()


def device_udid(name):
    devs = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    for rt in sorted(devs, reverse=True):
        for d in devs[rt]:
            if d["name"] == name:
                return d["udid"]
    sys.exit(f"no simulator named {name!r}")


def stage(device, scenes, wait_scale):
    udid = device_udid(device)
    run("xcrun", "simctl", "boot", udid, check=False)
    run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    run("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged",
        "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
    run("xcrun", "simctl", "ui", udid, "appearance", "light")
    run("xcrun", "simctl", "install", udid, APP, timeout=600)
    out = os.path.join(OUT, device)
    os.makedirs(out, exist_ok=True)
    for name in scenes:
        args, wait = SCENES[name]
        run("xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE, *args)
        time.sleep(wait * wait_scale)
        path = os.path.join(out, name + ".png")
        run("xcrun", "simctl", "io", udid, "screenshot", path)
        print("captured", path, flush=True)
    run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)


def upload_copies():
    """RGB copies at the sizes App Store Connect takes."""
    for device, folder, size in (("iPhone 18 Pro Max", "iPhone 6.3 (1206x2622) - upload these", (1206, 2622)),
                                 ("iPad Pro 13-inch (M5)", "iPad 13 (2064x2752) - upload these", (2064, 2752))):
        src, dst = os.path.join(OUT, device), os.path.join(OUT, folder)
        if not os.path.isdir(src):
            continue
        os.makedirs(dst, exist_ok=True)
        for f in sorted(os.listdir(src)):
            if not f.endswith(".png"):
                continue
            target = os.path.join(dst, f)
            run("sips", "-s", "format", "png", "-z", str(size[1]), str(size[0]), os.path.join(src, f), "--out", target)
            # Drop the alpha channel: App Store Connect rejects screenshots with one.
            run("sips", "-s", "format", "jpeg", target, "--out", target + ".jpg")
            run("sips", "-s", "format", "png", target + ".jpg", "--out", target)
            os.remove(target + ".jpg")
            print("upload copy", target, flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--device")
    ap.add_argument("--scene", action="append", choices=sorted(SCENES))
    ap.add_argument("--wait-scale", type=float, default=1.0)
    ap.add_argument("--upload", action="store_true")
    a = ap.parse_args()
    if a.device:
        stage(a.device, a.scene or sorted(SCENES), a.wait_scale)
    if a.upload:
        upload_copies()
