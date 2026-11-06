"""Synthetic, non-desktop model evaluation. Keys only come from ignored local config."""
import argparse, concurrent.futures, json, math, os, pathlib, statistics, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
APPS = [
    {"id":"com.apple.finder","name":"访达"},
    {"id":"com.apple.Safari","name":"Safari"},
    {"id":"com.google.Chrome","name":"Google Chrome"},
    {"id":"com.tencent.xinWeChat","name":"微信"},
    {"id":"com.apple.Notes","name":"备忘录"},
]
CASES = [
    ("声音有点吵，稍微压低一点就好，别静音。","down"),
    ("把声音控制在三成。","volume30"),
    ("微信调出来，我要接着看消息。","wechat"),
    ("别开微信了，我现在想看下载文件夹。","downloads"),
    ("先把Chrome叫出来，再给我留个空白网页。","chrome_tab"),
    ("Open Chrome, then search for GitHub Actions deployment examples.","chrome_search"),
    ("帮我在谷歌浏览器查一下Python decorators。","chrome_search"),
    ("只关这个网页，浏览器别退出。","close_tab"),
    ("先别打开任何东西，我只是打个招呼。","noop"),
    ("把刚才那个应用再叫出来。","finder"),
    ("这个我还要，别关。","noop"),
    ("刚才操作的是哪个应用，我忘了。","recent_reply"),
    ("Please type this exactly: Don't close Chrome. Keep GitHub Actions unchanged.","literal"),
    ("在微信里输入：Hello world，下午三点 review PR。","mixed"),
    ("把你好这两个字写到微信当前输入框里，不要发出去。","hello_wechat"),
    ("打开访达，顺便把声音设成百分之三十。","multi"),
    ("先暂停音乐，我接个电话。","pause"),
    ("在当前浏览器找一下 node.js stream backpressure 的资料。","search"),
    ("我想看下桌面。","desktop"),
    ("复制这段选中的文字。","copy"),
    ("刚才那步不要了，撤回一下。","undo"),
    ("这个内容我想全部选中。","select"),
    ("帮我把它弄一下。","clarify"),
    ("给张三发微信说我晚十分钟到。","unsupported"),
    ("删除下载里所有PDF。","unsupported"),
    ("运行终端命令 rm -rf ~/Downloads。","unsupported"),
    ("输入 Don't close Chrome. Copy the API docs!","literal2"),
    ("你好","noop"),
    ("微信输入你好","hello_wechat"),
    ("Everything.","clarify"),
]
HOLDOUT = [
    ("麻烦把微信切到前台，先不要输入任何东西。","wechat"),
    ("把音量设成20%，不要改静音状态。","volume20"),
    ("把声音降低10个百分点。","down"),
    ("我只要关掉这个标签，窗口留下。","close_tab"),
    ("撤回刚才的编辑。","undo"),
    ("在谷歌浏览器找Swift concurrency官方文档。","chrome_swift"),
    ("别弄微信，叫出Safari就行。","safari"),
    ("把 GitHub Actions 这两个英文单词原样写进文本编辑，不要回车。","textedit_literal"),
    ("我想给你说声谢谢，不用动电脑。","noop"),
    ("帮我把下载文件夹打开。","downloads"),
    ("桌面文件夹打开一下。","desktop_folder"),
    ("把正在写的东西都选上。","select"),
    ("把微信里的李四那条消息撤回。","unsupported"),
    ("把刚才那个应用切到前台。","finder"),
    ("清空废纸篓。","unsupported"),
]
def score(kind,p):
    a=p.get("steps",[]);d=p.get("decision")
    has=lambda k,**args:any(s.get("kind")==k and all(s.get(x)==v for x,v in args.items()) for s in a)
    app=lambda id:has("app",id=id,op="open")
    if kind in ["noop","clarify","unsupported"]:return d==kind and not a
    if kind=="unsupported_or_clarify":return d in ["unsupported","clarify"] and not a
    if kind=="recent_reply":return d=="noop" and ("访达" in (p.get("message","")+p.get("summary","")) or "Finder" in (p.get("message","")+p.get("summary","")))
    if d!="execute":return False
    if kind=="safari":return len(a)==1 and app("com.apple.Safari")
    if kind=="volume20":return len(a)==1 and has("volume",value=0.2) and all(s.get("muted") is None for s in a)
    if kind=="desktop_folder":return len(a)==1 and has("folder",name="desktop")
    if kind=="chrome_swift":return has("url",app="com.google.Chrome") and any("concurrency" in s.get("url","") for s in a)
    if kind=="textedit_literal":return len(a)==2 and app("com.apple.TextEdit") and has("text",text="GitHub Actions") and not any(s.get("enter") for s in a)
    if kind=="down":return len(a)==1 and has("volume",delta=-0.1) and not any(s.get("muted") for s in a)
    if kind=="volume30":return len(a)==1 and has("volume",value=0.3)
    if kind=="downloads":return len(a)==1 and has("folder",name="downloads")
    if kind=="wechat":return len(a)==1 and app("com.tencent.xinWeChat")
    if kind=="finder":return len(a)==1 and app("com.apple.finder")
    if kind=="chrome_tab":return app("com.google.Chrome") and has("system",name="newTab") and len(a)==2
    if kind=="chrome_search":return has("url",app="com.google.Chrome") and any("GitHub" in s.get("url","") or "Python" in s.get("url","") for s in a) and all(s.get("kind") in ["url","app"] or s.get("kind")=="system" and s.get("name")=="newTab" for s in a)
    if kind=="close_tab":return len(a)==1 and has("system",name="closeTab")
    if kind=="literal":return len(a)==1 and has("text",text="Don't close Chrome. Keep GitHub Actions unchanged.") and not any(s.get("enter") for s in a)
    if kind=="literal2":return len(a)==1 and has("text",text=" Don't close Chrome. Copy the API docs!") and not any(s.get("enter") for s in a)
    if kind=="mixed":return any(s.get("text")=="Hello world，下午三点 review PR。" for s in a) and all(s.get("kind") in ["app","text"] for s in a) and not any(s.get("enter") for s in a)
    if kind=="hello_wechat":return app("com.tencent.xinWeChat") and has("text",text="你好") and len(a)==2 and not any(s.get("enter") for s in a)
    if kind=="multi":return len(a)==2 and a[0].get("id")=="com.apple.finder" and a[1].get("value")==0.3
    if kind=="pause":return len(a)==1 and has("media",key="playPause")
    if kind=="search":return len(a)==1 and has("url") and "backpressure" in a[0].get("url","")
    if kind=="desktop":return len(a)==1 and has("system",name="showDesktop")
    return len(a)==1 and has("system",name={"copy":"copy","undo":"undo","select":"selectAll"}[kind])
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--limit",type=int,default=30);parser.add_argument("--suite",choices=["regression","holdout"],default="regression");parser.add_argument("--config",type=pathlib.Path,default=pathlib.Path(os.environ.get("CMDPALM_AI_CONFIG",str(pathlib.Path.home()/"Library/Application Support/CmdPalm AI/ai-config.json"))));args=parser.parse_args()
    base=json.loads(args.config.read_text())
    models=[("deepseek","deepseek-flash"),("qwen","qwen3.7-flash"),("qwen","qwen-flash")]
    result_dir=ROOT/"local-cache/evaluation"
    if args.suite=="holdout":result_dir=result_dir/"holdout"
    result_dir.mkdir(parents=True,exist_ok=True)
    def run_model(pair):
        provider,model=pair;c=json.loads(json.dumps(base));c["provider"]=provider;c[provider]["model"]=model
        cfg=result_dir/(provider+"-"+model+".private.json");cfg.write_text(json.dumps(c));cfg.chmod(0o600)
        rows=[]
        env=os.environ.copy();env["CMDPALM_AI_CONFIG"]=str(cfg)
        process=subprocess.Popen([str(ROOT/"local-cache/tools/intent-cli"),"--stream"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env,bufsize=1)
        seen_model=False
        try:
            for text,expected in (HOLDOUT if args.suite=="holdout" else CASES)[:args.limit]:
                env=os.environ.copy();env["CMDPALM_AI_CONFIG"]=str(cfg)
                payload={"text":text,"apps":APPS+([{"id":"com.apple.TextEdit","name":"TextEdit"}] if args.suite=="holdout" else []),"context":{"frontApp":"com.google.Chrome","recentApp":"com.apple.finder"}}
                started=time.monotonic()
                try:
                    process.stdin.write(json.dumps(payload)+"\n");process.stdin.flush()
                    plan=json.loads(process.stdout.readline());passed=score(expected,plan)
                except Exception as e:plan={"error":type(e).__name__};passed=False
                row={"text":text,"expected":expected,"passed":passed,"elapsedMs":round((time.monotonic()-started)*1000),"plan":plan}
                row["connection"]="warm" if seen_model else "cold"
                if plan.get("source")==provider:seen_model=True
                rows.append(row)
                (result_dir/(provider+"-"+model+".json")).write_text(json.dumps({"provider":provider,"configuredModel":model,"synthetic":True,"measurement":"one persistent native planner per model; no desktop execution","rows":rows},ensure_ascii=False,indent=2))
            calls=[x["elapsedMs"] for x in rows if x["plan"].get("source")==provider and x["connection"]=="warm"]
            summary={"provider":provider,"configuredModel":model,"passed":sum(x["passed"] for x in rows),"total":len(rows),"warmModelCalls":len(calls),"modelP50Ms":round(statistics.median(calls)) if calls else None,"modelP95Ms":sorted(calls)[max(0,math.ceil(len(calls)*.95)-1)] if calls else None,"failed":[{"text":x["text"],"plan":x["plan"]} for x in rows if not x["passed"]]}
            print(json.dumps(summary,ensure_ascii=False),flush=True)
            return summary
        finally:
            process.stdin.close()
            process.wait(timeout=10)
            cfg.unlink(missing_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        summaries=list(pool.map(run_model,models))
    (result_dir/"summary.json").write_text(json.dumps({"synthetic":True,"models":summaries},ensure_ascii=False,indent=2))
if __name__=="__main__":main()
