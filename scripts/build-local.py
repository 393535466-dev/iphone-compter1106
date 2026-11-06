"""Build the fork with Command Line Tools and official, checksum-verified resource/framework inputs."""
import argparse, hashlib, json, os, pathlib, plistlib, shutil, subprocess, urllib.request, zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument("--sdk",default="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk");args=p.parse_args()
tools=ROOT/"local-cache/tools"
env=os.environ.copy()
env["PATH"]=str(tools/"cargo/bin")+":"+str(tools)+":"+env.get("PATH","")
env["CARGO_HOME"]=str(tools/"cargo");env["RUSTUP_HOME"]=str(tools/"rustup")
env["CMDPALM_BUILD_SDK"]=args.sdk
def run(command,**kwargs):
    subprocess.run([str(x) for x in command],cwd=ROOT,env=env,check=True,**kwargs)
def source_asset():
    directory=ROOT/"local-cache/vendor";directory.mkdir(parents=True,exist_ok=True)
    archive=directory/"CmdPalm-0.6.0.zip"
    def download(url):
        return urllib.request.urlopen(urllib.request.Request(url,headers={"User-Agent":"CmdPalm-AI-source-build"}),timeout=30).read()
    release=json.loads(download("https://api.github.com/repos/rahatsagor/CmdPalm/releases/tags/v0.6.0"))
    assets={a["name"]:a for a in release["assets"]}
    checks=download(assets["SHA256SUMS"]["browser_download_url"]).decode()
    expected=next(line.split()[0] for line in checks.splitlines() if line.rstrip().endswith(archive.name))
    if not archive.exists():archive.write_bytes(download(assets[archive.name]["browser_download_url"]))
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:raise SystemExit("Official resource archive checksum mismatch.")
    with zipfile.ZipFile(archive) as z:
        if any(".." in n.split("/") or n.startswith("/") for n in z.namelist()):raise SystemExit("Unsafe resource archive.")
    output=directory/"extracted"
    if not (output/"CmdPalm.app").exists():run(["ditto","-x","-k",archive,output])
    return output/"CmdPalm.app"
source=source_asset()
run(["bash","scripts/build-core.sh"])
run([tools/"bun","run","--cwd","web","build"])
app=ROOT/"build/Development/CmdPalm AI.app";app.parent.mkdir(parents=True,exist_ok=True)
if app.exists():shutil.rmtree(app)
run(["ditto",source,app])
sources=sorted((ROOT/"apple/CmdPalm").rglob("*.swift"))+[ROOT/"apple/Generated/cmdpalm_core.swift"]
frameworks=app/"Contents/Frameworks"
binary=app/"Contents/MacOS/CmdPalm"
run(["xcrun","swiftc","-swift-version","6","-O","-D","CMDPALM_LOCAL_BUILD","-target","arm64-apple-macos15.0","-sdk",args.sdk,
     "-I",ROOT/"apple/Generated","-Xcc","-fmodule-map-file="+str(ROOT/"apple/Generated/cmdpalm_coreFFI.modulemap"),
     "-F",frameworks,"-framework","IOKit","-framework","Carbon","-framework","CoreGraphics",
     "-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks",
     *sources,ROOT/"target/aarch64-apple-darwin/release/libcmdpalm_core.a","-o",binary])
info=app/"Contents/Info.plist"
with info.open("rb") as f:d=plistlib.load(f)
d.update(CFBundleIdentifier="dev.iphonecomputer.CmdPalmAI",CFBundleDisplayName="CmdPalm AI",CFBundleName="CmdPalm AI",
         CFBundleExecutable="CmdPalm",CFBundleShortVersionString="0.7.0",CFBundleVersion="700",
         SUFeedURL="https://github.com/393535466-dev/iphone-compter1106/releases/latest/download/appcast.xml",
         SUPublicEDKey="")
with info.open("wb") as f:plistlib.dump(d,f)
web=app/"Contents/Resources/web"
if web.exists():shutil.rmtree(web)
shutil.copytree(ROOT/"web/dist",web)
# Reuse upstream's stable local signing identity when installed. No root trust changes.
identity=env.get("CMDPALM_SIGN_IDENTITY","")
if not identity:
    known=subprocess.run(["security","find-identity","-p","codesigning"],capture_output=True,text=True,check=True).stdout
    identity="CmdPalm Self-Signed" if '"CmdPalm Self-Signed"' in known else "-"
if identity=="-": print("Development-only ad-hoc signature: Accessibility may need re-granting after rebuild.")
run(["codesign","--force","--timestamp=none","--sign",identity,"--options","runtime","--entitlements",ROOT/"apple/CmdPalm/CmdPalm.entitlements",app])
run(["codesign","--verify","--deep","--strict",app])
print("Built source application: "+str(app))
